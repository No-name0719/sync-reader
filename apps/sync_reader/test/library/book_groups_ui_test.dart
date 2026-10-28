/// 分组 UI 测试（FR-107 本地分类）：分组过滤栏渲染与过滤、书卡长按拖拽
/// 归组/移出、分组管理对话框（新建/重名拒绝/重命名/删除回未分组）。
/// 注入内存库 + 临时目录存储，沿用 library_page_test 的 pump 手法。
///
/// 注意：testWidgets 的 fakeAsync 中真实 IO（临时目录/文件）必须经
/// `tester.runAsync` 执行；widget 内的 drift 流（假定时器驱动）由
/// pumpAndSettle 正常驱动。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

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
  }) => BooksCompanion.insert(
    bookId: id,
    title: title,
    format: 'txt',
    fileName: '$id.txt',
    contentHash: 'sha256:$id',
    sizeBytes: 1024,
    tocFingerprint: 'tfp:0000000000000000',
    addedAt: addedAt,
    localPath: const Value('/books/x'),
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
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 长按拖拽（FR-107）：长按 [from] 超过阈值进入 Draggable 后，
  /// 分步移动到 [to] 上方抬起落点。
  Future<void> longPressDrag(
    WidgetTester tester,
    Finder from,
    Finder to,
  ) async {
    final start = tester.getCenter(from);
    final end = tester.getCenter(to);
    final gesture = await tester.startGesture(start);
    // 超过 kLongPressTimeout（500ms）触发 LongPressDraggable。
    await tester.pump(const Duration(milliseconds: 600));
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

  /// 管理对话框范围（以其标题为锚，避免匹配到背后的确认/重命名对话框）。
  Finder manageDialog(WidgetTester tester) =>
      find.ancestor(of: find.text('管理分组'), matching: find.byType(AlertDialog));

  /// 书目可见性断言：封面与卡片标题各渲染一次书名，用 findsWidgets。
  Future<void> expectBookVisible(String title, bool visible) async {
    expect(find.textContaining(title), visible ? findsWidgets : findsNothing);
  }

  testWidgets('分组栏渲染：全部/未分组/管理常驻，建组后出现分组 chip', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.bookGroupsDao.createGroup('组A');
      await db!.bookGroupsDao.createGroup('组B');
      await db!.booksDao.upsertCompanion(bookRow('B1', title: 'Alpha'));
    });
    await pumpLibrary(tester);

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);
    expect(find.text('组A'), findsOneWidget);
    expect(find.text('组B'), findsOneWidget);
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

    // 默认「全部」：两本都显示。
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);

    // 未分组：只留 Beta。
    await tester.tap(find.text('未分组'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', false);
    await expectBookVisible('Beta', true);

    // 组A：只留 Alpha。
    await tester.tap(find.text('组A'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', false);

    // 回到「全部」：恢复显示。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);
    await shutdown(tester);
  });

  testWidgets('拖拽归组：长按书卡拖到组 chip 移入，拖到「未分组」移出', (tester) async {
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
    await tester.tap(find.text('组A'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', true);

    // 回「全部」，把 Alpha 拖到「未分组」→ 移出分组。
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    await longPressDrag(tester, find.text('Alpha').first, find.text('未分组'));
    expect(find.text('已移出分组'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await db!.booksDao.getById('B2'))?.groupId, isNull);
    });

    // 「未分组」视图同时出现 Alpha 与未组书，组内书 Beta 不再显示。
    await tester.tap(find.text('未分组'));
    await tester.pumpAndSettle();
    await expectBookVisible('Alpha', true);
    await expectBookVisible('Beta', false);
    await shutdown(tester);
  });

  testWidgets('管理对话框：新建分组；重名 SnackBar 拒绝', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);

    // 打开管理对话框并新建「组A」。
    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
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
    // 对话框列表与背后 chip 栏同步出现「组A」（drift watch 自动刷新）。
    expect(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(ListTile, '组A'),
      ),
      findsOneWidget,
    );
    expect(find.text('组A'), findsNWidgets(2));

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

  testWidgets('管理对话框：重命名即时生效并同步 chip 栏', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.bookGroupsDao.createGroup('组A');
    });
    await pumpLibrary(tester);

    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
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
    expect(find.text('组C'), findsNWidgets(2)); // 对话框 + chip 栏
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

    await tester.tap(find.byType(ActionChip));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('分组操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 确认对话框（冻结文案）→ 确认删除。
    expect(find.text('删除分组不会删除书籍，组内书籍将回到未分组。'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 分组消失（chip 栏 + 对话框），组内书回未分组。
    expect(
      find.descendant(of: manageDialog(tester), matching: find.text('组A')),
      findsNothing,
    );
    await tester.runAsync(() async {
      expect((await db!.booksDao.getById('B1'))?.groupId, isNull);
    });

    // 关闭对话框：书库页不再有「组A」chip，Alpha 归入未分组视图。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('组A'), findsNothing);
    await tester.tap(find.text('未分组'));
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
