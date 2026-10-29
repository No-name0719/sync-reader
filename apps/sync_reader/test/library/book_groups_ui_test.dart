/// 分组 UI 测试（FR-107 本地分类 + v1.1 A4/A18/A20）：两层筛选（状态
/// chip × 分组下拉）、书卡拖拽归组（**仅鼠标指针**，FR-107×A20 手势冲突
/// 解法：触屏长按出上下文菜单）、分组管理对话框。
/// 注入内存库 + 临时目录存储，沿用 library_page_test 的 pump 手法。
///
/// 注意：testWidgets 的 fakeAsync 中真实 IO（临时目录/文件）必须经
/// `tester.runAsync` 执行；widget 内的 drift 流（假定时器驱动）由
/// pumpAndSettle 正常驱动。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart'
    show secureCredentialStoreProvider;

void main() {
  AppDatabase? db;
  Directory? tmp;

  /// 建库 + 临时目录（真实 IO 经 runAsync）。
  Future<void> bootstrap(WidgetTester tester) async {
    await tester.runAsync(() async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      await database.customSelect('SELECT 1').getSingle();
      db = database;
      tmp = await Directory.systemTemp.createTemp('book_groups_ui_test');
    });
  }

  /// 断言失败时也保证关闭库（否则残留的 drift 定时器让后续测试级联挂起）。
  Future<void> bootstrapSafely(WidgetTester tester) async {
    await bootstrap(tester);
    addTearDown(() async {
      if (db != null) {
        await tester.pump(const Duration(seconds: 60));
        await tester.runAsync(() async => db?.close());
        db = null;
      }
    });
  }

  /// 测试体收尾：排空 drift 流查询的更新定时器后在真实区关闭库。
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
    await tester.runAsync(() async {
      await db?.close();
      db = null;
    });
  }

  BooksCompanion bookRow(
    String id, {
    String title = '书',
    int addedAt = 1000,
    String? groupId,
    String? localPath = '/books/x',
  }) => BooksCompanion.insert(
    bookId: id,
    title: title,
    format: 'txt',
    fileName: '$id.txt',
    contentHash: 'sha256:$id',
    sizeBytes: 1024,
    tocFingerprint: 'tfp:0000000000000000',
    addedAt: addedAt,
    localPath: Value(localPath),
    groupId: Value(groupId),
  );

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryPage()),
      GoRoute(
        path: '/book/:bookId',
        builder: (_, _) =>
            const Scaffold(key: Key('detail-stub'), body: Text('详情页-stub')),
      ),
    ],
  );

  Future<void> pumpLibrary(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          // 注入内存凭据存储，避免测试环境触碰平台通道。
          secureCredentialStoreProvider.overrideWithValue(
            InMemoryCredentialStore(),
          ),
        ],
        child: MaterialApp.router(
          // 书库页消费设计令牌（A2）：测试骨架必须挂 AppTheme。
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: buildRouter(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 鼠标长按拖拽（FR-107）：长按 [from] 超过阈值进入 Draggable（落点栏随
  /// onDragStarted 浮现）后，再定位 [to]（此时才存在于树中）分步移动抬起。
  /// 必须用鼠标指针（A20：触屏长按已让给上下文菜单）。
  Future<void> longPressDrag(
    WidgetTester tester,
    Finder from,
    Finder to,
  ) async {
    final start = tester.getCenter(from);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    // 超过 kLongPressTimeout（500ms）触发 LongPressDraggable → 落点栏浮现。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    final end = tester.getCenter(to);
    const steps = 10;
    for (var i = 1; i <= steps; i++) {
      await gesture.moveBy(
        Offset((end.dx - start.dx) / steps, (end.dy - start.dy) / steps),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// 经分组下拉选择过滤项（菜单打开后取菜单内条目）。
  Future<void> pickGroup(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('筛选分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// 经分组下拉打开分组管理对话框。
  Future<void> openManageDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('筛选分组'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理分组…'));
    await tester.pumpAndSettle();
  }

  /// 管理对话框范围（以其标题为锚，避免匹配到背后的确认/重命名对话框）。
  Finder manageDialog(WidgetTester tester) =>
      find.ancestor(of: find.text('管理分组'), matching: find.byType(AlertDialog));

  /// 书目可见性断言：封面与卡片标题各渲染一次书名，用 findsWidgets。
  Future<void> expectBookVisible(String title, bool visible) async {
    expect(find.textContaining(title), visible ? findsWidgets : findsNothing);
  }

  testWidgets('筛选栏：状态 chip 四项常驻 + 分组下拉菜单（全部/未分组/各分组/管理）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.bookGroupsDao.createGroup('组A');
      await db!.bookGroupsDao.createGroup('组B');
      await db!.booksDao.upsertCompanion(bookRow('B1', title: 'Alpha'));
    });
    await pumpLibrary(tester);

    // 状态 chip 行常驻（互斥单选，A4）；「全部」默认选中。
    expect(find.text('全部'), findsOneWidget);
    expect(find.text('已同步'), findsOneWidget);
    expect(find.text('仅本地'), findsOneWidget);
    expect(find.text('仅云端'), findsOneWidget);
    // 分组下拉按钮（图标 + 文字 + 箭头）。
    expect(find.text('全部分组'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选分组'));
    await tester.pumpAndSettle();
    // 菜单：全部分组（按钮标签 + 菜单项共两处）+ 未分组 + 两个分组 + 管理。
    expect(find.text('全部分组'), findsNWidgets(2));
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('组A'), findsOneWidget);
    expect(find.text('组B'), findsOneWidget);
    expect(find.text('管理分组…'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('状态 chip「仅云端」过滤：占位书单独可见，切回全部恢复（Q21 含已删除）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.booksDao.upsertCompanion(bookRow('B1', title: 'Alpha'));
      await db!.booksDao.upsertCompanion(
        bookRow('B2', title: 'Placeholder', localPath: null),
      );
      await db!.booksDao.upsertCompanion(
        bookRow('B3', title: 'Deleted', localPath: null),
      );
      await db!
          .into(db!.deletedBooks)
          .insert(
            DeletedBooksCompanion.insert(
              bookId: 'B3',
              deletedAt: 1000,
              contentHash: 'sha256:B3',
            ),
          );
    });
    await pumpLibrary(tester);

    await expectBookVisible('Alpha', true);
    await expectBookVisible('Placeholder', true);

    // 仅云端 chip：占位书与已删除书（Q21 同桶），有正文的书隐藏。
    await tester.tap(find.text('仅云端'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', false);
    await expectBookVisible('Placeholder', true);
    await expectBookVisible('Deleted', true);

    // 回「全部」：恢复显示。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Placeholder', true);
    await shutdown(tester);
  });

  testWidgets('分组过滤：点「未分组」只显示未分组书，点组名只显示组内书', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final groupA = await db!.bookGroupsDao.createGroup('组A');
      await db!.booksDao.upsertCompanion(
        bookRow('B1', title: 'Alpha', groupId: groupA.groupId),
      );
      await db!.booksDao.upsertCompanion(bookRow('B2', title: 'Beta'));
    });
    await pumpLibrary(tester);

    // 默认「全部分组」：两本都显示。
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);

    // 未分组：只留 Beta（按钮标签同步为当前过滤）。
    await pickGroup(tester, '未分组');
    await expectBookVisible('Alpha', false);
    await expectBookVisible('Beta', true);
    expect(find.text('未分组'), findsWidgets); // 按钮 + chip 行之外的下拉标签

    // 组A：只留 Alpha。
    await pickGroup(tester, '组A');
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', false);

    // 回「全部分组」：恢复显示。
    await pickGroup(tester, '全部分组');
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);
    await shutdown(tester);
  });

  testWidgets('拖拽归组（鼠标）：长按书卡拖到组 chip 移入，拖到「未分组」移出', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final groupA = await db!.bookGroupsDao.createGroup('组A');
      await db!.booksDao.upsertCompanion(
        bookRow('B1', title: 'Beta', addedAt: 1000, groupId: groupA.groupId),
      );
      await db!.booksDao.upsertCompanion(
        bookRow('B2', title: 'Alpha', addedAt: 2000),
      );
    });
    await pumpLibrary(tester);

    // Alpha（未分组）拖到「组A」chip → 移入。
    await longPressDrag(tester, find.text('Alpha').first, find.text('组A'));
    expect(find.text('已移入「组A」'), findsOneWidget);
    String? alphaGroupId;
    await tester.runAsync(() async {
      alphaGroupId = (await db!.booksDao.getById('B2'))?.groupId;
    });
    final groupAId = (await tester.runAsync(
      () => db!.bookGroupsDao.allGroups(),
    ))!.firstWhere((g) => g.name == '组A').groupId;
    expect(alphaGroupId, groupAId);

    // 切到「组A」视图：组内出现 Alpha（流重查生效）。
    await pickGroup(tester, '组A');
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);

    // 回「全部分组」，把 Alpha 拖到落点栏「未分组」→ 移出分组。
    await pickGroup(tester, '全部分组');
    await longPressDrag(tester, find.text('Alpha').first, find.text('未分组'));
    expect(find.text('已移出分组'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await db!.booksDao.getById('B2'))?.groupId, isNull);
    });

    // 「未分组」视图同时出现 Alpha 与未组书，组内书 Beta 不再显示。
    await pickGroup(tester, '未分组');
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', false);
    await shutdown(tester);
  });

  testWidgets('触屏长按书卡：弹上下文菜单而非拖拽（A20 手势冲突解法）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.bookGroupsDao.createGroup('组A');
      await db!.booksDao.upsertCompanion(bookRow('B1', title: 'Alpha'));
    });
    await pumpLibrary(tester);

    // 触屏长按（默认 gesture kind = touch）→ 菜单浮现，落点栏不出现。
    await tester.longPress(find.text('Alpha').first);
    await tester.pumpAndSettle();
    expect(find.text('移动到分组…'), findsOneWidget);
    expect(find.text('拖到分组归组'), findsNothing);

    // 经菜单「移动到分组…」归组（触屏统一走菜单，FR-107×A20）。
    await tester.tap(find.text('移动到分组…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('组A'));
    await tester.pumpAndSettle();
    expect(find.text('已移入「组A」'), findsOneWidget);
    await tester.runAsync(() async {
      final groupAId = (await db!.bookGroupsDao.allGroups())
          .firstWhere((g) => g.name == '组A')
          .groupId;
      expect((await db!.booksDao.getById('B1'))?.groupId, groupAId);
    });
    await shutdown(tester);
  });

  testWidgets('管理对话框：新建分组；重名 SnackBar 拒绝', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);

    // 打开管理对话框并新建「组A」。
    await openManageDialog(tester);
    expect(find.text('管理分组'), findsOneWidget);
    final dialog = manageDialog(tester);
    final newField = find.descendant(
      of: dialog,
      matching: find.byType(TextField),
    );
    final createButton = find.descendant(of: dialog, matching: find.text('新建'));
    await tester.enterText(newField, '组A');
    // pump 让"新建"按钮按输入刷新可用态。
    await tester.pump();
    await tester.tap(createButton);
    // createGroup 走 drift 事务，完成回调经假定时器调度，pumpAndSettle
    // 不保证排空：定长泵显式推进时间。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    // 对话框列表出现「组A」（drift watch 自动刷新）。
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(ListTile, '组A'),
      ),
      findsOneWidget,
    );
    expect(find.text('组A'), findsOneWidget);

    // 重名拒绝：SnackBar 提示，且列表中仍只有一个「组A」行。
    await tester.enterText(newField, '组A');
    await tester.pump();
    await tester.tap(createButton);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('分组名「组A」已存在'), findsOneWidget);
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(ListTile, '组A'),
      ),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      expect(await db!.bookGroupsDao.nameExists('组A'), isTrue);
    });
    await shutdown(tester);
  });

  testWidgets('管理对话框：重命名即时生效', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.bookGroupsDao.createGroup('组A');
    });
    await pumpLibrary(tester);

    await openManageDialog(tester);
    await tester.tap(find.byTooltip('分组操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    // 重命名对话框（预填旧名）→ 改名保存。
    final renameDialog = find.ancestor(
      of: find.text('重命名分组'),
      matching: find.byType(AlertDialog),
    );
    await tester.enterText(
      find.descendant(of: renameDialog, matching: find.byType(TextField)),
      '组C',
    );
    await tester.tap(
      find.descendant(of: renameDialog, matching: find.text('保存')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: manageDialog(tester), matching: find.text('组C')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: manageDialog(tester), matching: find.text('组A')),
      findsNothing,
    );
    expect(find.text('组C'), findsOneWidget); // 对话框行
    await shutdown(tester);
  });

  testWidgets('管理对话框：删除分组后组内书籍回未分组', (tester) async {
    await bootstrapSafely(tester);
    late String groupId;
    await tester.runAsync(() async {
      final groupA = await db!.bookGroupsDao.createGroup('组A');
      groupId = groupA.groupId;
      await db!.booksDao.upsertCompanion(
        bookRow('B1', title: 'Alpha', groupId: groupId),
      );
    });
    await pumpLibrary(tester);

    await openManageDialog(tester);
    await tester.tap(find.byTooltip('分组操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 确认对话框（冻结文案）→ 确认删除。
    expect(find.text('删除分组不会删除书籍，组内书籍将回到未分组。'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 分组消失（对话框行 + 筛选菜单），组内书回未分组。
    expect(
      find.descendant(of: manageDialog(tester), matching: find.text('组A')),
      findsNothing,
    );
    await tester.runAsync(() async {
      expect((await db!.booksDao.getById('B1'))?.groupId, isNull);
    });

    // 关闭对话框：筛选菜单不再有「组A」，Alpha 归入未分组视图。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('筛选分组'));
    await tester.pumpAndSettle();
    expect(find.text('组A'), findsNothing);
    await tester.tap(find.text('未分组').last);
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await shutdown(tester);
  });

  tearDown(() async {
    await db?.close();
    final dir = tmp;
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    db = null;
    tmp = null;
  });
}
