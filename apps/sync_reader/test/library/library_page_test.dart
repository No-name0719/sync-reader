/// 书库首页 widget 测试（FR-105/106）：网格/列表切换与持久化、排序、
/// 防抖搜索、空态、去详情导航、错误态。注入内存库 + 临时目录存储。
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
import 'package:sync_reader/features/library/import/batch_import_controller.dart';
import 'package:sync_reader/features/library/library_providers.dart';

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

  /// [picker] / [batchImporting] / [fakeIdleBatch]：批量导入（FR-109）
  /// 用例的注入开关（Riverpod 3 不导出 Override 类型，用开关而非
  /// override 列表参数）。
  Future<void> pumpLibrary(
    WidgetTester tester, {
    DirectoryPicker? picker,
    bool batchImporting = false,
    bool fakeIdleBatch = false,
  }) async {
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
            InMemoryCredentialStore(),
          ),
          if (picker != null) directoryPickerProvider.overrideWithValue(picker),
          if (batchImporting)
            batchImportControllerProvider.overrideWith(
              _ImportingController.new,
            ),
          if (fakeIdleBatch)
            batchImportControllerProvider.overrideWith(_IdleController.new),
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空书库显示空态', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget); // 导入入口
    await shutdown(tester);
  });

  testWidgets('网格显示书名/进度/时长/仅云端角标', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(() async {
      final database = db!;
      await database.booksDao.upsertCompanion(
        bookRow('01A', title: 'AAA', lastReadAt: 900),
      );
      await database.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      );
      await database.progressDao.upsert(
        bookId: '01A',
        locatorJson: '{}',
        percent: 0.42,
      );
      await database.booksDao.updateProgressInfo('01A', totalSeconds: 1800);
    });
    await pumpLibrary(tester);

    expect(find.text('AAA'), findsWidgets); // 封面小字 + 卡片标题
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('30 分钟'), findsOneWidget);
    expect(find.text('仅云端'), findsOneWidget); // 占位书角标
    await shutdown(tester);
  });

  testWidgets('网格/列表切换并持久化（reader_settings.library_view）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    await pumpLibrary(tester);

    expect(find.byType(ListTile), findsNothing);
    await tester.tap(find.byIcon(Icons.view_list));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    // 值落库（JSON 字符串 "list"）。
    await tester.runAsync(() async {
      expect(await db!.readerSettingsDao.getValue('library_view'), '"list"');
    });

    // 新容器重建 → 从库里恢复列表模式。
    // 注意：同位置的 ProviderScope 重新 pump 时 override 数量必须一致
    //（riverpod 调试断言），否则新树构建即抛异常。
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
        ],
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
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
    await tester.tap(find.byIcon(Icons.view_list));
    await tester.pumpAndSettle();
    List<ListTile> tiles() =>
        tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect((tiles().first.title as Text).data, 'BBB');

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书名'));
    await tester.pumpAndSettle();
    expect((tiles().first.title as Text).data, 'AAA');
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

  testWidgets('点击卡片进入详情路由', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(bookRow('01A', title: 'AAA')),
    );
    final router = buildRouter();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db!),
          bookFileStoreProvider.overrideWith(
            (ref) async => BookFileStore(tmp!),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('详情页-stub'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('点击占位书卡片：触发下载分流，未配置同步 → 提示且不导航（FR-402）', (tester) async {
    await bootstrapSafely(tester);
    await tester.runAsync(
      () => db!.booksDao.upsertCompanion(
        bookRow('01B', title: 'BBB', localPath: null),
      ),
    );
    final router = buildRouter();
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
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('BBB').first);
    await tester.pumpAndSettle();
    expect(find.text('尚未配置同步账号，请先在"同步设置"中完成配置'), findsOneWidget);
    // 保持书库路由（未进详情/阅读器）。
    expect(find.text('详情页-stub'), findsNothing);
    await shutdown(tester);
  });

  // ---- 批量导入入口（FR-109）----

  testWidgets('溢出菜单提供批量导入入口（默认可用）', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(
      find.byType(PopupMenuItem<String>).first,
    );
    expect(item.enabled, isTrue);
    expect(find.text('批量导入（文件夹）'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('批量导入进行中：入口与单本导入按钮禁用（防重入）', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester, batchImporting: true);
    // 单本导入按钮禁用。
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add).first)
          .onPressed,
      isNull,
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(
      find.byType(PopupMenuItem<String>).first,
    );
    expect(item.enabled, isFalse);
    await shutdown(tester);
  });

  testWidgets('选择目录后推送批量导入确认页（目录选择器注入）', (tester) async {
    await bootstrapSafely(tester);
    final dir = tmp!;
    await pumpLibrary(
      tester,
      picker: _FakeDirectoryPicker(dir.path),
      // 假控制器：确认页 initState 的 startScan 不做真实 IO（fakeAsync
      // 中真实文件 IO 不可靠），页面稳定停留在"扫描中"提示。
      fakeIdleBatch: true,
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量导入（文件夹）'));
    // 路由过渡动画 + 确认页 initState；确认页初始为扫描中（含不确定
    // 进度圈），只能定长泵推进，不能 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('批量导入'), findsOneWidget); // 确认页 AppBar 标题
    expect(find.text('正在扫描文件夹…'), findsOneWidget);
    await shutdown(tester);
  });

  testWidgets('取消选择目录：静默留在书库', (tester) async {
    await bootstrapSafely(tester);
    await pumpLibrary(tester, picker: const _FakeDirectoryPicker(null));
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量导入（文件夹）'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('批量导入'), findsNothing);
    // 应用名不再作书库页标题（右上角让位筛选入口）。
    expect(find.text('SyncReader'), findsNothing);
    await shutdown(tester);
  });

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
        child: MaterialApp.router(routerConfig: buildRouter()),
      ),
    );
    // 错误流经 Riverpod 的定时/微任务链送达，需要显式时间泵推进
    //（静态 loading 占位不产生持续帧，pumpAndSettle 会立即返回）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    for (final t in tester.widgetList<Text>(find.byType(Text))) {
      // ignore: avoid_print
      print('TXT[${t.data}]');
    }
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.textContaining('书库加载失败'), findsOneWidget);
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

/// 假目录选择器：返回预置路径（null = 模拟用户取消）。
final class _FakeDirectoryPicker implements DirectoryPicker {
  const _FakeDirectoryPicker(this.result);

  final String? result;

  @override
  Future<String?> pickDirectory() async => result;
}

/// 假批量导入控制器：空闲态，startScan 不做真实扫描。
final class _IdleController extends BatchImportController {
  @override
  BatchImportState build() => const BatchImportState();

  @override
  Future<void> startScan(String directoryPath) async {}
}

/// 假批量导入控制器：恒为导入中（验证入口禁用）。
final class _ImportingController extends BatchImportController {
  @override
  BatchImportState build() =>
      const BatchImportState(phase: BatchImportPhase.importing);

  @override
  Future<void> startScan(String directoryPath) async {}
}
