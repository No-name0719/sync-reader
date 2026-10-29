/// FR-601 飞行模式全链路用例——共享测试环境（目录内自洽，不改动生产代码）。
///
/// "无网络"前置的注入手法（沿用 test/sync 的既有风格）：
/// - connectivity 经 [OfflineEnv.connectivity] 广播流注入 `SyncTriggers`
///   （override `syncTriggersProvider`，同 sync_triggers_test 的注入位）；
///   挂载后发射 `[ConnectivityResult.none]` 即为飞行模式；
/// - 云端侧注入 [FailingBackendAdapter]（凭据配置齐全、引擎可构建，
///   但一切云端操作必败）——模拟"有同步账号但飞行模式"，且零真实网络；
/// - 未配置场景（默认）凭据留空：门面 `readConfig` 返回 null，同步全程
///   no-op，天然零网络。
///
/// 注意：Riverpod 3 不导出 `Override` 类型，故 overrides 列表一律以字面量
/// 内联在 [pumpOfflineApp]/[OfflineEnv.makeContainer] 中（元素类型经上下文
/// 推断；手法同 library_page_test 的"开关而非 override 列表参数"注记）。
///
/// 真实 IO（临时目录/文件）一律经 `tester.runAsync` 执行（fakeAsync 限制，
/// 手法同 test/library/book_detail_page_test.dart 的 settleReal）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/app.dart' show SyncTriggerHost;
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/library/book_detail_page.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_controller.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/reader_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_preferences.dart';
import 'package:sync_reader/features/sync/sync_triggers.dart';

/// 1x1 PNG（最小合法图字节；与 test/library/fake_handler.dart 的 tinyPng
/// 同源，目录内自洽故此处内联一份）。
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

/// 三章长文本（足够翻页/滚动产生进度；同 test/reader/txt 的夹具口径）。
final String longBookText =
    '第一章 开端\n${'甲' * 2000}\n'
    '第二章 发展\n${'乙' * 2000}\n'
    '第三章 结局\n${'丙' * 2000}\n';

/// 同步触发记录器：断言"触发来源/推送调用"用。
final class SyncCallRecorder {
  /// fullSync 触发来源序列（按时间序）。
  final List<SyncTriggerSource> sources = [];

  /// 单书 meta 推送的 bookId 序列。
  final List<String> pushes = [];
}

/// 必败适配器：connect 可成功（引擎得以构建），其余一切云端操作抛同一
/// 错误——模拟飞行模式下"有账号但网络不可达/认证失效"，零真实网络。
/// 各方法带调用计数，供"同步确实尝试过且失败"断言。
final class FailingBackendAdapter implements BackendAdapter {
  FailingBackendAdapter(this.error);

  /// 所有云端操作抛出的错误（NetworkUnreachable / BackendRequestException 等）。
  final Object error;

  int connectCalls = 0;
  int ensureLayoutCalls = 0;
  int listMetasCalls = 0;
  int getMetaCalls = 0;
  int putMetaCalls = 0;

  @override
  BackendKind get kind => BackendKind.webdav;

  @override
  Future<void> connect(BackendConfig cfg) async => connectCalls++;

  @override
  Future<BackendCapabilities> probeCapabilities() async => throw error;

  @override
  Future<void> ensureLayout() async {
    ensureLayoutCalls++;
    throw error;
  }

  @override
  Future<String?> readLibraryJson() async => throw error;

  @override
  Future<void> deleteMeta(String bookId) async => throw error;

  @override
  Future<MetaListing> listMetas({String? cursor}) async {
    listMetasCalls++;
    throw error;
  }

  @override
  Future<List<CloudBookFile>> listBookFiles() async => throw error;

  @override
  Future<void> deleteBookFile(String name) async => throw error;

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) async {
    getMetaCalls++;
    throw error;
  }

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) async {
    putMetaCalls++;
    throw error;
  }

  @override
  Future<void> putTombstone(
    BookMeta tombstoned, {
    required int expectedRev,
  }) async {
    putMetaCalls++;
    throw error;
  }

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) async* {
    throw error;
  }

  @override
  Future<void> uploadBook(
    String bookId,
    File file,
    String contentHash, {
    bool overwrite = false,
  }) async => throw error;

  @override
  Future<void> dispose() async {}
}

/// 带创建计数的适配器供应：`createCalls == 0` 证明全程未触碰云端
/// （导入/离线零网络断言用）；命中创建时返回 [factory] 产物（默认内存
/// 适配器，绝不发真实请求）。
final class CountingAdapterProvider implements SyncAdapterProvider {
  CountingAdapterProvider({BackendAdapter Function()? factory})
    : factory = factory ?? InMemoryAdapter.new;

  /// 实际创建适配器的工厂（默认内存适配器）。
  final BackendAdapter Function() factory;

  int createCalls = 0;

  @override
  BackendAdapter create(BackendConfig config) {
    createCalls++;
    return factory();
  }
}

/// 固定适配器供应（注入 [FailingBackendAdapter] 用；手法同
/// test/sync/sync_facade_test.dart 的 _FixedAdapterProvider）。
final class FixedAdapterProvider implements SyncAdapterProvider {
  FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}

/// 离线测试环境：内存库 + 临时目录存储 + 注入式 connectivity 流。
///
/// 创建涉及真实 IO，widget 测试须在 `tester.runAsync` 内调用 [create]
/// 并对结果取 `!`（runAsync 返回可空）。
final class OfflineEnv {
  OfflineEnv._(
    this.db,
    this.store,
    this.tmpDir,
    this.connectivity,
    this.recorder,
    this.credentials,
  );

  final AppDatabase db;
  final BookFileStore store;
  final Directory tmpDir;

  /// connectivity 注入流：挂载后发射 `[ConnectivityResult.none]` = 飞行模式。
  final StreamController<List<ConnectivityResult>> connectivity;
  final SyncCallRecorder recorder;
  final InMemoryCredentialStore credentials;

  static Future<OfflineEnv> create() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final dir = await Directory.systemTemp.createTemp('offline_flight');
    final store = BookFileStore(dir);
    await store.ensureLayout();
    return OfflineEnv._(
      db,
      store,
      dir,
      StreamController<List<ConnectivityResult>>.broadcast(),
      SyncCallRecorder(),
      InMemoryCredentialStore(),
    );
  }

  /// 写入 WebDAV 凭据（仅内存，不触碰平台安全存储）：让门面得以构建引擎，
  /// 从而覆盖"有同步账号但飞行模式"的失败路径。
  Future<void> configureCredentials() async {
    await credentials.save(SecureKeys.webdavAccount, 'reader@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
  }

  /// 基础注入集（仅限展开进 `overrides:` 字面量使用——Riverpod 3 不导出
  /// Override 类型，元素类型经上下文推断）。
  ///
  /// - 触发器注入：connectivity 用本环境广播流（默认实现会触碰平台通道）；
  ///   runSync/pushBookMeta 透传真实门面并留痕，便于断言触发与静默；
  /// - [adapterProvider]：替换云端适配器供应（必败/计数适配器注入位）；
  /// - [registry]：替换格式注册表（阅读页静默性用例注入零 IO 假 handler）。
  List<dynamic> _injection({
    SyncAdapterProvider? adapterProvider,
    FormatRegistry? registry,
  }) => [
    databaseProvider.overrideWithValue(db),
    bookFileStoreProvider.overrideWith((ref) async => store),
    secureCredentialStoreProvider.overrideWithValue(credentials),
    if (adapterProvider != null)
      syncAdapterProvider.overrideWithValue(adapterProvider),
    if (registry != null) formatRegistryProvider.overrideWithValue(registry),
    syncTriggersProvider.overrideWith((ref) {
      final facade = ref.watch(syncFacadeProvider);
      final triggers = SyncTriggers(
        runSync: (source) async {
          recorder.sources.add(source);
          return facade.fullSync(source: source);
        },
        pushBookMeta: (bookId) async {
          recorder.pushes.add(bookId);
          await facade.pushBookMeta(bookId);
        },
        preferences: () => ref.read(syncPreferencesProvider),
        connectivityStream: connectivity.stream,
      );
      ref.onDispose(triggers.detach);
      return triggers;
    }),
  ];

  /// 组装注入完毕的 ProviderContainer（需读状态/手动触发同步的用例使用；
  /// 用毕须 dispose，dispose 前应先卸载挂靠的 widget 树）。
  ProviderContainer makeContainer({
    SyncAdapterProvider? adapterProvider,
    FormatRegistry? registry,
  }) => ProviderContainer(
    overrides: [
      ..._injection(adapterProvider: adapterProvider, registry: registry),
    ],
  );

  /// 收尾：关流、关库、删临时目录（在 runAsync 真实区执行；调用前应已
  /// 卸载 widget 树，使 drift 流订阅与触发器定时器先行释放）。
  Future<void> dispose() async {
    await connectivity.close();
    await db.close();
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  }
}

/// 挂载完整应用骨架：注入环境 + 触发器宿主 + 全部真实页面路由
/// （书库 / 详情 / 阅读器；不复用全局 router 单例，避免用例间导航串扰，
/// 手法同 test/library/library_page_test.dart）。
///
/// [mountTriggers] = false 时跳过触发器宿主（v1.1 书库流程变长后，个别
/// 用例的断言窗口会越过启动 2s 全量定时器，需要隔离定时同步的干扰）。
/// 书库页自 v1.1 起消费设计令牌（A2）：App 骨架必须挂 AppTheme。
Future<void> pumpOfflineApp(
  WidgetTester tester,
  OfflineEnv env, {
  SyncAdapterProvider? adapterProvider,
  bool mountTriggers = true,
}) async {
  final app = MaterialApp.router(
    theme: AppTheme.light(AppAccent.terracotta),
    routerConfig: offlineRouter(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...env._injection(adapterProvider: adapterProvider)],
      child: mountTriggers ? SyncTriggerHost(child: app) : app,
    ),
  );
}

/// 用应用路由表（书库/详情/阅读器）构建全新 GoRouter。
GoRouter offlineRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const LibraryPage()),
    GoRoute(
      path: '/book/:bookId',
      builder: (context, state) =>
          BookDetailPage(bookId: state.pathParameters['bookId']!),
    ),
    GoRoute(
      path: '/reader/:bookId',
      builder: (context, state) =>
          ReaderPage(bookId: state.pathParameters['bookId']!),
    ),
  ],
);

/// 断言当前树上没有任何阻塞式报错 UI：错误对话框与 SnackBar。
///
/// FR-601 验收口径：飞行模式下核心链路无网络调用报错弹窗——同步失败只允许
/// 进 FR-406 状态横幅（非阻塞），不得打断阅读/导入/删除。
void expectNoBlockingErrorUi(WidgetTester tester, {String reason = ''}) {
  expect(
    find.byType(Dialog),
    findsNothing,
    reason: '不允许阻塞式对话框（AlertDialog/SimpleDialog）$reason',
  );
  expect(
    find.byType(SnackBar),
    findsNothing,
    reason: '不允许 SnackBar（同步失败应只进状态横幅）$reason',
  );
}

/// 让 fakeAsync 内由 widget 回调发起的真实 IO 完成，再推进 UI。
/// 真实 IO 的完成事件经真实事件循环投递：每进一次 runAsync 窗口推进
/// 串行链的一环（打开阅读器的解码/渲染链、删除的文件移动等）。
Future<void> settleReal(WidgetTester tester, {int windows = 12}) async {
  for (var i = 0; i < windows; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// 测试体收尾：先卸载 widget 树（容器 dispose → 触发器 detach/drift 流
/// 取消），再排空残余定时器，最后在真实区关闭库并清理环境。
/// 直接 close 会因等待 fake 定时器驱动的流清理而挂起；不关闭则触发
/// pending-timer invariant。
Future<void> shutdownOfflineApp(WidgetTester tester, OfflineEnv env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 60));
  await tester.runAsync(env.dispose);
}

/// 造一本书行（字段可覆盖；手法同 test/library/library_page_test.bookRow）。
BooksCompanion bookRow(
  String id, {
  String title = '离线书',
  String author = '',
  String format = 'txt',
  String fileName = '离线书.txt',
  int sizeBytes = 1024,
  String? localPath = '/books/x.txt',
  String? coverPath,
  int addedAt = 1000,
}) => BooksCompanion.insert(
  bookId: id,
  title: title,
  author: Value(author),
  format: format,
  fileName: fileName,
  contentHash: 'sha256:$id',
  sizeBytes: sizeBytes,
  tocFingerprint: 'tfp:0000000000000000',
  addedAt: addedAt,
  localPath: Value(localPath),
  coverPath: Value(coverPath),
);

// ── 阅读页静默性用例的零 IO 假渲染器（手法同 test/features/reader/integration）──

/// 最小假控制器：记录 restore；进度锚点/百分比可注入。
final class OfflineFakeReaderController extends ReaderController {
  final List<ProgressAnchor> restoreCalls = [];

  /// currentLocator/percent 的返回值（模拟已读到位置）。
  ProgressAnchor locator = ProgressAnchor.empty;
  double percentValue = 0;

  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async {
    restoreCalls.add(saved);
    return ReaderRestoreResult(
      mode: saved.hasProgress
          ? ReaderRestoreMode.exact
          : ReaderRestoreMode.noProgress,
      applied: saved,
    );
  }

  @override
  ProgressAnchor get currentLocator => locator;

  @override
  double get percent => percentValue;

  @override
  Future<void> jumpTo(TocEntry entry) async {}

  @override
  Future<bool> nextPage() async => false;

  @override
  Future<bool> previousPage() async => false;

  @override
  void dispose() {}
}

/// 最小假渲染器：静态视图（无 IO、无动画，pumpAndSettle 必收敛）。
final class OfflineFakeRenderer extends BookRenderer {
  @override
  final OfflineFakeReaderController controller = OfflineFakeReaderController();

  bool disposed = false;

  @override
  Widget buildView(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('offline-fake-renderer-view'));

  @override
  void dispose() => disposed = true;
}

/// 最小假 handler：parseMetadata 零 IO 固定返回，createRenderer 返回注入
/// 的渲染器（不传则新建）。
final class OfflineFakeHandler implements BookFormatHandler {
  OfflineFakeHandler({this.renderer, this.toc = const []});

  /// createRenderer 返回的渲染器（测试持有句柄做断言）；null 则每次新建。
  final OfflineFakeRenderer? renderer;

  @override
  final String formatId = 'txt';

  /// parseMetadata 返回的目录。
  final List<TocEntry> toc;

  @override
  bool canHandle(String ext, Uint8List magicHeader) => ext == 'txt';

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async => ParsedBook(
    title: '假书名',
    author: '假作者',
    toc: toc,
    tocFingerprint: 'tfp:0123456789abcdef',
  );

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) async => renderer ?? OfflineFakeRenderer();
}
