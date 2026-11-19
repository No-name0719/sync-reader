/// 书库首页 widget 测试（FR-105/106 + v1.1 A3/A4/A5/A13/A18/A20）：
/// 两层筛选与分面计数、书卡状态胶囊与上下文菜单、点封面直接开书（含
/// 未下载触发下载）、导入确认弹窗与「同时上传到云端」开关、四档宽度
/// 冒烟。注入内存库 + 临时目录存储。
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
import 'package:sync_reader/features/library/import/batch_import_controller.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/shell/app_shell.dart';
import 'package:sync_reader/shared/cover_view.dart';
import 'package:sync_reader/features/library/library_providers.dart';
import 'package:sync_reader/features/library/widgets/book_cards.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
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
      tmp = await Directory.systemTemp.createTemp('library_page_test');
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
  /// 不排空则 close 等待 fake 定时器驱动的清理而挂起；不关闭则
  /// "Timer is still pending" invariant 失败。
  Future<void> shutdown(WidgetTester tester) async {
    // 先卸载整个 widget 树：Riverpod 容器销毁 → drift 流订阅取消，
    // 使 close 无需等待流清理；再排空残余定时器，最后在真实区关闭库。
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
    String author = '',
    String format = 'txt',
    int addedAt = 1000,
    int? lastReadAt,
    String? localPath = '/books/x',
    String? groupId,
    String? coverPath,
  }) => BooksCompanion.insert(
    bookId: id,
    title: title,
    author: Value(author),
    format: format,
    fileName: '$id.$format',
    contentHash: 'sha256:$id',
    sizeBytes: 1024,
    tocFingerprint: 'tfp:0000000000000000',
    addedAt: addedAt,
    localPath: Value(localPath),
    lastReadAt: Value(lastReadAt),
    groupId: Value(groupId),
    coverPath: Value(coverPath),
  );

  /// 插入「云端有」（sync_state baseRev 行，已同步桶的必要条件）。
  Future<void> seedCloudBase(String bookId) async {
    await db!
        .into(db!.syncState)
        .insert(
          SyncStateCompanion.insert(
            bookId: bookId,
            backendKey: 'webdav',
            baseRev: 1,
            lastSyncedAt: 1000,
          ),
        );
  }

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const LibraryPage()),
      GoRoute(
        path: '/book/:bookId',
        builder: (_, _) =>
            const Scaffold(key: Key('detail-stub'), body: Text('详情页-stub')),
      ),
      // Q15：点封面直接进阅读器（书库页分流后 push 的路由）。
      GoRoute(
        path: '/reader/:bookId',
        builder: (_, _) =>
            const Scaffold(key: Key('reader-stub'), body: Text('阅读页-stub')),
      ),
      // A16：分裂按钮「批量导入（文件夹）」→ /tools/batch-import（批 7 接线）。
      GoRoute(
        path: '/tools/batch-import',
        builder: (_, _) => const Scaffold(
          key: Key('batch-import-stub'),
          body: Text('批量导入-stub'),
        ),
      ),
    ],
  );

  /// [picker] / [batchImporting] / [importService] / [credentials]：注入
  /// 开关（Riverpod 3 不导出 Override 类型，用开关而非 override 列表参数）。
  Future<void> pumpLibrary(
    WidgetTester tester, {
    LibraryFilePicker? picker,
    bool batchImporting = false,
    BookImportService? importService,
    CredentialStore? credentials,
    bool wide = false,
  }) async {
    if (wide) {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          // 占位书分流（FR-402）会触碰同步门面：注入内存凭据存储，
          // 避免测试环境触碰平台通道（未存凭据 → readConfig 返回 null）。
          secureCredentialStoreProvider.overrideWithValue(
            credentials ?? InMemoryCredentialStore(),
          ),
          // 同步门面必须用内存适配器：默认供应是真实 WebDAV（网络 IO 在
          // fakeAsync 中永不完成，测试会挂起）。
          syncAdapterProvider.overrideWithValue(
            const InMemorySyncAdapterProvider(),
          ),
          if (picker != null)
            libraryFilePickerProvider.overrideWithValue(picker),
          if (batchImporting)
            batchImportControllerProvider.overrideWith(
              _ImportingController.new,
            ),
          if (importService != null)
            bookImportServiceProvider.overrideWithValue(importService),
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


  testWidgets('空书库显示空态', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget); // 导入分裂按钮主区
    await shutdown(tester);
  });

  testWidgets('网格显示书名/进度胶囊/时长/未下载角标（A5/A20）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final database = db!;
      // 已同步 + 有进度（dirty=false → 百分比胶囊）。
      await database.booksDao.upsertCompanion(
        bookRow('01A', title: 'AAA', lastReadAt: 900, coverPath: 'c.png'),
      );
      await seedCloudBase('01A');
      await database.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{}',
        percent: 0.42,
        dirty: false,
      );
      await database.booksDao.updateProgressInfo('01A', totalSeconds: 1800);
      // 占位书（未下载胶囊）。
      await database.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      );
    });
    await pumpLibrary(tester);

    expect(find.text('AAA'), findsWidgets); // 封面小字 + 卡片标题
    expect(find.text('42%'), findsOneWidget); // 右上角品牌胶囊
    expect(find.text('30 分钟'), findsOneWidget); // ⏱ 时长行（Q7）
    expect(find.text('未下载'), findsOneWidget); // 占位书墨色胶囊
    // 旧版黑色百分比遮条已移除：百分比不重复出现。
    expect(find.text('42%'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('胶囊优先级：同步失败 > 待上传 > 仅本地 > 未下载 > 百分比（A5）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final database = db!;
      // 待上传（dirty=true 优先于百分比）。
      await database.booksDao.upsertCompanion(bookRow('B1', title: '待上传书'));
      await seedCloudBase('B1');
      await database.progressDao.upsert(
        bookId: 'B1',
        locatorJson: '{}',
        percent: 0.5,
      ); // dirty 默认 true
      // 仅本地（本地标记表命中，云端没有）。
      await database.booksDao.upsertCompanion(bookRow('B2', title: '仅本地书'));
      await database.localOnlyBooksDao.markLocalOnly('B2');
      // 未下载（占位）。
      await database.booksDao.upsertCompanion(
        bookRow('B3', title: '占位书', localPath: null),
      );
      // 百分比（已同步 + 非 dirty 进度）。
      await database.booksDao.upsertCompanion(
        bookRow('B4', title: '已同步书', coverPath: 'c.png'),
      );
      await seedCloudBase('B4');
      await database.progressDao.upsert(
        bookId: 'B4',
        locatorJson: '{}',
        percent: 0.42,
        dirty: false,
      );
    });
    await pumpLibrary(tester);

    expect(find.text('待上传'), findsOneWidget);
    // 「仅本地」出现两次：状态 chip 常驻文案 + 书卡胶囊（文案相同）。
    expect(find.text('仅本地'), findsNWidgets(2));
    expect(find.text('未下载'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    // 待上传书不再显示百分比胶囊（优先级）。
    expect(find.text('50%'), findsNothing);
    await shutdown(tester);
  });

  testWidgets('两层筛选取交集：状态 chip 过滤 + 结果概要（A4/A18）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final group1 = await db!.bookGroupsDao.createGroup('小说');
      // 已同步（云端有 + 正文）。
      await db!.booksDao.upsertCompanion(
        bookRow('S1', title: '已同步书', groupId: group1.groupId),
      );
      await seedCloudBase('S1');
      // 仅本地（标记表）。
      await db!.booksDao.upsertCompanion(bookRow('L1', title: '仅本地书'));
      await db!.localOnlyBooksDao.markLocalOnly('L1');
      // 仅云端 ×2（占位 + 已删除，Q21 同桶）。
      await db!.booksDao.upsertCompanion(
        bookRow('C1', title: '占位书', localPath: null),
      );
      await db!.booksDao.upsertCompanion(
        bookRow('C2', title: '已删除书', localPath: null),
      );
      await seedCloudBase('C2');
    });
    await pumpLibrary(tester);

    // 默认「全部」：全部可见，概要为「共 N 本」。
    expect(find.text('已同步书'), findsWidgets);
    expect(find.text('共 4 本'), findsOneWidget);

    // 切「仅云端」chip：占位书 + 已删除书可见（交集），概要联动。
    await tester.tap(find.text('仅云端'));
    await tester.pumpAndSettle();
    expect(find.text('占位书'), findsWidgets);
    expect(find.text('已删除书'), findsWidgets);
    expect(find.text('已同步书'), findsNothing);
    expect(find.text('仅本地书'), findsNothing);
    expect(find.text('匹配 2 / 4 本'), findsOneWidget);

    // 切「仅本地」chip。
    await tester.tap(find.text('仅本地'));
    await tester.pumpAndSettle();
    expect(find.text('仅本地书'), findsWidgets);
    expect(find.text('占位书'), findsNothing);
    expect(find.text('匹配 1 / 4 本'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('分组下拉过滤 + 状态×分组计数联动（A4/A18）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final group1 = await db!.bookGroupsDao.createGroup('小说');
      await db!.booksDao.upsertCompanion(
        bookRow('S1', title: '已同步书', groupId: group1.groupId),
      );
      await seedCloudBase('S1');
      await db!.booksDao.upsertCompanion(bookRow('L1', title: '仅本地书'));
      await db!.localOnlyBooksDao.markLocalOnly('L1');
    });
    await pumpLibrary(tester);

    // 分组下拉：默认「全部分组」；菜单含未分组/各分组/管理入口。
    expect(find.text('全部分组'), findsOneWidget);
    await tester.tap(find.byTooltip('筛选分组'));
    await tester.pumpAndSettle();
    expect(find.text('未分组'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('管理分组…'), findsOneWidget);

    // 选「未分组」：只剩未组内的仅本地书。
    await tester.tap(find.text('未分组').last);
    await tester.pumpAndSettle();
    expect(find.text('已同步书'), findsNothing);
    expect(find.text('仅本地书'), findsWidgets);
    expect(find.text('匹配 1 / 2 本'), findsOneWidget);

    // 交集为空：未分组 × 已同步 → 筛选空态（含清除筛选）。
    await tester.tap(find.text('已同步'));
    await tester.pumpAndSettle();
    expect(find.text('没有符合条件的书'), findsOneWidget);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('已同步书'), findsWidgets);
    expect(find.text('共 2 本'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('网格/列表切换并持久化（reader_settings.library_view）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    await pumpLibrary(tester);

    expect(find.byType(BookListTile), findsNothing);
    await tester.tap(find.byIcon(Icons.view_list_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(BookListTile), findsOneWidget);
    // 值落库（JSON 字符串 "list"）。
    await tester.runAsync(() async {
      expect(await db!.readerSettingsDao.getValue('library_view'), '"list"');
    });

    // 新容器重建 → 从库里恢复列表模式。
    // 注意：同位置的 ProviderScope 重新 pump 时 override 数量/顺序必须与
    // pumpLibrary 一致（riverpod 调试断言），否则新树构建即抛异常。
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
          secureCredentialStoreProvider.overrideWithValue(
            InMemoryCredentialStore(),
          ),
          syncAdapterProvider.overrideWithValue(
            const InMemorySyncAdapterProvider(),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: buildRouter(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(BookListTile), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('排序切换即时生效（默认最近阅读 → 书名）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.booksDao.upsertCompanion(
        bookRow('01A', title: 'AAA', lastReadAt: 800),
      );
      await db!.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', lastReadAt: 900),
      );
    });
    await pumpLibrary(tester);
    // 切列表便于断言顺序。
    await tester.tap(find.byIcon(Icons.view_list_outlined));
    await tester.pumpAndSettle();
    List<String> titles() => tester
        .widgetList<BookListTile>(find.byType(BookListTile))
        .map((t) => t.book.title)
        .toList();
    expect(titles().first, 'BBB');

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书名'));
    await tester.pumpAndSettle();
    expect(titles().first, 'AAA');
    await shutdown(tester);
  });

  testWidgets('搜索 300ms 防抖后过滤（FR-106）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      await db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA'));
      await db!.booksDao.upsertCompanion(bookRow('01B', title: 'BBB'));
    });
    await pumpLibrary(tester);

    await tester.enterText(find.byType(TextField), 'AA');
    // 防抖窗口内：还未过滤。
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('BBB'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('BBB'), findsNothing);
    expect(find.text('AAA'), findsWidgets);

    // 清空恢复。
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('BBB'), findsWidgets);
    await shutdown(tester);
  });

  testWidgets('点击有正文的卡片直接进阅读器（Q15：点封面直接开书）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    await pumpLibrary(tester);
    await tester.tap(find.text('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('阅读页-stub'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('点击占位书卡片：触发下载分流，未配置同步 → 提示且不导航（FR-402）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      ),
    );
    await pumpLibrary(tester);

    await tester.tap(find.text('BBB').first);
    await tester.pumpAndSettle();
    expect(find.text('尚未配置同步账号，请先在"同步设置"中完成配置'), findsOneWidget);
    // 保持书库路由（未进阅读器）。
    expect(find.text('阅读页-stub'), findsNothing);
    await shutdown(tester);
  });

  testWidgets('点击未下载卡片 + 已配置同步：进入下载链路，失败轻提示不导航', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      ),
    );
    // SyncFacade 是 final class（禁止测试子类化）：用真实门面 + 已配置凭据 +
    // 默认内存适配器驱动下载链路——点卡片即触发 facade.downloadPlaceholder，
    // 出现常驻下载提示（fakeAsync 中下载的文件 IO 不会完成，提示保留）。
    final credentials = InMemoryCredentialStore();
    await tester.runAsync(() async {
      await credentials.save(SecureKeys.webdavAccount, 'user');
      await credentials.save(SecureKeys.webdavPassword, 'pass');
    });
    await pumpLibrary(tester, credentials: credentials);

    await tester.tap(find.text('BBB').first);
    await tester.pumpAndSettle();
    // 下载链路确实被触发（配置校验通过 → 常驻下载提示），且不进阅读器。
    expect(find.textContaining('正在下载'), findsOneWidget);
    expect(find.text('阅读页-stub'), findsNothing);
    await shutdown(tester);
  });

  // ---- 上下文菜单（A20：触屏长按 / 桌面右键，按状态裁剪）----

  testWidgets('长按未下载书：菜单有「下载正文」，无上传/设为仅本地/继续阅读', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(
        bookRow('01B', title: '占位书', localPath: null),
      ),
    );
    await pumpLibrary(tester);

    await tester.longPress(find.text('占位书').first);
    await tester.pumpAndSettle();
    expect(find.text('下载正文'), findsOneWidget);
    expect(find.text('继续阅读（42%）'), findsNothing);
    expect(find.text('开始阅读'), findsNothing);
    expect(find.text('上传到云端'), findsNothing);
    expect(find.text('设为仅本地'), findsNothing);
    expect(find.text('书籍信息'), findsOneWidget);
    expect(find.text('移动到分组…'), findsOneWidget);
    expect(find.text('删除本书'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('长按仅本地书：有「上传到云端」无「设为仅本地」；长按已同步书反之', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      // 仅本地：有正文 + 标记表命中。
      await db!.booksDao.upsertCompanion(bookRow('L1', title: '仅本地书'));
      await db!.localOnlyBooksDao.markLocalOnly('L1');
      // 已同步：有正文 + 云端有。
      await db!.booksDao.upsertCompanion(bookRow('S1', title: '已同步书'));
      await seedCloudBase('S1');
    });
    await pumpLibrary(tester);

    // 仅本地书。
    await tester.longPress(find.text('仅本地书').first);
    await tester.pumpAndSettle();
    expect(find.text('上传到云端'), findsOneWidget);
    expect(find.text('设为仅本地'), findsNothing);
    expect(find.text('开始阅读'), findsOneWidget); // 有正文 → 阅读/继续阅读
    expect(find.text('书籍信息'), findsOneWidget);
    // 点空白处关闭菜单。
    await tester.tapAt(const Offset(20, 60));
    await tester.pumpAndSettle();

    // 已同步书：反之。
    await tester.longPress(find.text('已同步书').first);
    await tester.pumpAndSettle();
    expect(find.text('设为仅本地'), findsOneWidget);
    expect(find.text('上传到云端'), findsNothing);
    await shutdown(tester);
  });

  testWidgets('长按菜单「移动到分组…」→ 选组后 setGroup 落库（A20 复用归组逻辑）', (tester) async {
    await bootstrapSafely(tester);
    late String groupId;
    await tester.runAsync(() async {
      final groupA = await db!.bookGroupsDao.createGroup('组A');
      groupId = groupA.groupId;
      await db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA'));
    });
    await pumpLibrary(tester);

    await tester.longPress(find.text('AAA').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到分组…'));
    await tester.pumpAndSettle();
    expect(find.text('移动到分组'), findsOneWidget); // 对话框标题
    await tester.tap(find.text('组A'));
    await tester.pumpAndSettle();
    expect(find.text('已移入「组A」'), findsOneWidget);
    await tester.runAsync(() async {
      expect((await db!.booksDao.getById('01A'))?.groupId, groupId);
    });
    await shutdown(tester);
  });

  testWidgets('长按菜单「删除本书」→ 确认后移出书库（正文删盘 + 删行 + 墓碑）', (tester) async {
    await bootstrapSafely(tester);
    final store = BookFileStore(tmp!);
    final localPath = (await tester.runAsync(() async {
      final path = store.resolveBookPath('01A', 'txt');
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString('正文', flush: true);
      return path;
    }))!;
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(
        bookRow('01A', title: '待删书', localPath: localPath),
      ),
    );
    await pumpLibrary(tester);

    await tester.longPress(find.text('待删书').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除本书'));
    await tester.pumpAndSettle();
    // 确认文案与详情页一致（docs/10 §4.7b）。
    expect(find.text('删除《待删书》？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pump();
    // 删除的删盘是真实 IO：进 runAsync 窗口等文件消失
    // （offline_env settleReal 同款手法），再继续断言。
    await tester.runAsync(() async {
      for (var i = 0; i < 20 && File(localPath).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    await tester.pumpAndSettle();

    // 书目从书库消失（回归：删除后不该再以「未下载」残影留在书库里）
    // + 墓碑入账 + 正文删盘。
    expect(find.text('待删书'), findsNothing);
    await tester.runAsync(() async {
      expect(await db!.booksDao.getById('01A'), isNull);
      final ledger = await db!.select(db!.deletedBooks).get();
      expect(ledger, hasLength(1));
      expect(File(localPath).existsSync(), isFalse);
    });
    await shutdown(tester);
  });

  // ---- 导入（A13：分裂按钮 + 确认弹窗 + 常驻进度）----

  testWidgets('分裂按钮：背景色块高度贴着内容（不再被 48px 箭头按钮撑高）', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);

    // 品牌色底的那颗按钮（分裂按钮的根 Material）。
    final button = find
        .ancestor(
          of: find.byKey(const Key('library-import-main')),
          matching: find.byType(Material),
        )
        .first;
    final height = tester.getSize(button).height;
    expect(
      height,
      lessThanOrEqualTo(34),
      reason:
          '导入按钮高度应贴着内容（实测 $height）——此前箭头那半边的 '
          'IconButton 默认 48×48，把整颗按钮的背景色块撑到 48 高，'
          '看着「背景框高度太大」',
    );

    // 主区文字与按钮居中对齐（「＋」图标与文字同一水平中心）。
    final main = tester.getRect(find.byKey(const Key('library-import-main')));
    final label = tester.getRect(find.text('导入'));
    final plus = tester.getRect(find.byIcon(Icons.add));
    expect(
      label.center.dy,
      closeTo(main.center.dy, 1.0),
      reason: '「导入」文字应与按钮主区居中对齐',
    );
    expect(
      (plus.center.dy - label.center.dy).abs(),
      lessThan(0.5),
      reason: '「＋」图标应与「导入」文字光学对齐',
    );

    await shutdown(tester);
  });

  testWidgets('导入按钮：品牌色底上的浮层是半透明淡染（不洗成灰白）', (
    tester,
  ) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);

    final context = tester.element(
      find.byKey(const Key('library-import-main')),
    );
    final themeHover = Theme.of(context).hoverColor;
    expect(
      themeHover.a,
      equals(1.0),
      reason: '主题的 hoverColor 是不透明的表面色——铺在品牌色底上会把按钮'
          '整块洗成灰白（用户实测「鼠标放在发布按钮会有一层灰色」）',
    );

    // 主区（InkWell）：必须显式指定浮层色，且是**半透明**淡染。
    final inkWell = tester.widget<InkWell>(
      find.byKey(const Key('library-import-main')),
    );
    final overlay = inkWell.overlayColor;
    expect(
      overlay,
      isNotNull,
      reason: '品牌色底上的浮层必须显式指定，否则回落到主题那块不透明的浅灰',
    );
    final hovered = overlay!.resolve({WidgetState.hovered});
    expect(hovered, isNotNull);
    expect(
      hovered!.a,
      lessThan(1.0),
      reason: '浮层应是半透明淡染（色相不变），不能是不透明的表面色',
    );
    expect(hovered, isNot(themeHover));

    // 浮层叠到品牌色上的**实际结果**：修复前是不透明浅灰 → 按钮变灰白；
    // 修复后是半透明白 → 仍是赭石（红显著高于绿）。
    final layered = Color.lerp(
      Theme.of(context).extension<AppDesignTokens>()!.brand,
      hovered,
      hovered.a,
    )!;
    expect(
      layered.r - layered.g,
      greaterThan(0.19),
      reason: '叠上浮层后按钮仍应是品牌色（赭石），实测 $layered',
    );

    // 箭头半边（PopupMenuButton 内部的 IconButton）：同样要求半透明淡染。
    final popup = tester.widget<PopupMenuButton<String>>(
      find
          .ancestor(
            of: find.byTooltip('更多导入方式'),
            matching: find.byType(PopupMenuButton<String>),
          )
          .first,
    );
    final style = popup.style;
    expect(style, isNotNull, reason: '箭头半边也必须指定浮层色');
    final arrowHovered = style!.overlayColor!.resolve({WidgetState.hovered});
    expect(arrowHovered, isNotNull);
    expect(
      arrowHovered!.a,
      lessThan(1.0),
      reason: '箭头半边的浮层同样不能是不透明的表面色',
    );

    await shutdown(tester);
  });

  testWidgets('分裂按钮下拉提供「导入文件… / 批量导入（文件夹）」入口；点批量导入落 /tools/batch-import', (
    tester,
  ) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);
    await tester.tap(find.byTooltip('更多导入方式'));
    await tester.pumpAndSettle();
    expect(find.text('导入文件…'), findsOneWidget);
    expect(find.text('批量导入（文件夹）'), findsOneWidget);
    // 批 7 接线验证：菜单项点击后落到批量导入页（A16）。
    await tester.tap(find.text('批量导入（文件夹）'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('batch-import-stub')), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('批量导入进行中：分裂按钮主区与下拉禁用（FR-109 防重入）', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester, batchImporting: true);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('library-import-main')))
          .onTap,
      isNull,
    );
    // 下拉箭头（PopupMenuButton）整体禁用，菜单打不开。
    expect(
      tester
          .widget<PopupMenuButton<String>>(
            find.widgetWithIcon(PopupMenuButton<String>, Icons.arrow_drop_down),
          )
          .enabled,
      isFalse,
    );
    await shutdown(tester);
  });

  testWidgets('导入确认弹窗：默认勾选上传 + 流量预估；取消勾选出现不上传提示（Q18）', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(AppAccent.terracotta),
        home: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                result = await showImportConfirmDialog(
                  context,
                  files: const [
                    ImportFileEntry(
                      name: 'a.txt',
                      sizeBytes: 42 * 1024 * 1024 + 600 * 1024,
                    ),
                    ImportFileEntry(name: 'b.epub', sizeBytes: 1024),
                  ],
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 文件清单（名 + 大小）。
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('b.epub'), findsOneWidget);
    expect(find.text('42.6 MB'), findsOneWidget);
    // 默认勾选 + 流量预估文案。
    final checkbox = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '同时上传到云端'),
    );
    expect(checkbox.value, isTrue);
    expect(find.text('预计上行 42.6 MB · 坚果云免费额度 1 GB / 月'), findsOneWidget);

    // 取消勾选 → 提示切换为不上传说明；确认返回 false。
    await tester.tap(find.text('同时上传到云端'));
    await tester.pumpAndSettle();
    expect(find.text('其它设备看不到这几本书'), findsOneWidget);
    await tester.tap(find.text('导入 2 本'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('确认弹窗保持勾选 → importFiles 收到 uploadToCloud: true', (tester) async {
    await bootstrapSafely(tester);
    final spy = _SpyImportService(
      booksDao: db!.booksDao,
      registry: FormatRegistry(),
      fileStore: Future.value(BookFileStore(tmp!)),
    );
    await pumpLibrary(
      tester,
      picker: const _FakeFilePicker(),
      importService: spy,
    );

    await tester.tap(find.byKey(const Key('library-import-main')));
    await tester.pumpAndSettle();
    expect(find.text('导入书籍'), findsOneWidget);
    // 保持默认勾选，确认导入。
    await tester.tap(find.text('导入 1 本'));
    await tester.pumpAndSettle();
    expect(spy.uploadCalls, [true]);
    // 完成汇总（成功 n / 失败 m）。
    expect(find.textContaining('导入完成：成功 0 本，失败 0 本'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('确认弹窗取消勾选 → importFiles 收到 uploadToCloud: false（Q18）', (
    tester,
  ) async {
    await bootstrapSafely(tester);
    final spy = _SpyImportService(
      booksDao: db!.booksDao,
      registry: FormatRegistry(),
      fileStore: Future.value(BookFileStore(tmp!)),
    );
    await pumpLibrary(
      tester,
      picker: const _FakeFilePicker(),
      importService: spy,
    );

    await tester.tap(find.byKey(const Key('library-import-main')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同时上传到云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 1 本'));
    await tester.pumpAndSettle();
    expect(spy.uploadCalls, [false]);
    await shutdown(tester);
  });

  // ---- 稳定性 ----

  testWidgets('书库流错误 → 空态标题 + 错误提示', (tester) async {
    await bootstrapSafely(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          booksStreamProvider.overrideWith(
            (ref) => Stream.error(Exception('db boom')),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: buildRouter(),
        ),
      ),
    );
    // 错误流经 Riverpod 的定时/微任务链送达，需要显式时间泵推进
    //（静态 loading 占位不产生持续帧，pumpAndSettle 会立即返回）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.textContaining('书库加载失败'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('四档宽度（1440/1180/860/390）无横向溢出冒烟', (tester) async {
    for (final width in <double>[1440, 1180, 860, 390]) {
      await bootstrap(tester);
      await tester.runAsync(() async {
        final group = await db!.bookGroupsDao.createGroup('组A');
        await db!.booksDao.upsertCompanion(
          bookRow('01A', title: '较长书名用来验证换行是否触发溢出报错的书', groupId: group.groupId),
        );
        await db!.booksDao.upsertCompanion(
          bookRow('01B', title: 'BBB', localPath: null),
        );
      });
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpLibrary(tester);
      // 渲染期间不得抛溢出异常（RenderFlex overflow 以异常形式冒出）。
      expect(tester.takeException(), isNull, reason: '宽度 $width 溢出');
      expect(find.text('BBB'), findsWidgets);
      await shutdown(tester);
    }
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

/// 假文件选择器：返回预置条目（空 = 模拟用户取消）。
final class _FakeFilePicker implements LibraryFilePicker {
  const _FakeFilePicker();

  @override
  Future<List<ImportFilePick>> pickImportFiles() async => const [
    ImportFilePick(path: '/fake/a.txt', name: 'a.txt', sizeBytes: 1024),
  ];
}

/// 侦察导入服务：只记录 uploadToCloud 开关，不执行导入流水线。
final class _SpyImportService extends BookImportService {
  _SpyImportService({
    required super.booksDao,
    required super.registry,
    required super.fileStore,
  });

  final List<bool> uploadCalls = [];

  @override
  Future<ImportSummary> importFiles(
    List<String> paths, {
    void Function(ImportProgress progress)? onProgress,
    bool uploadToCloud = true,
  }) async {
    uploadCalls.add(uploadToCloud);
    return ImportSummary();
  }
}

/// 记录型同步门面已移除：SyncFacade 为 final class 禁止子类化，
/// 下载链路改用真实门面 + 已配置凭据 + 内存适配器驱动（见对应用例）。

/// 假批量导入控制器：恒为导入中（验证入口禁用）。
final class _ImportingController extends BatchImportController {
  @override
  BatchImportState build() =>
      const BatchImportState(phase: BatchImportPhase.importing);

  @override
  Future<void> startScan(String directoryPath) async {}
}
