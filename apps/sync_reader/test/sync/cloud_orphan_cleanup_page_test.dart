/// 云端孤儿清理页 widget 测试（docs/04 §7.1 规则 4 手动清理工具 UI）：
/// 未配置态、空态、列表/合计、单文件删除成功移除与失败保留、批量清理
/// 进度与暂停/继续/汇总、清单错误重试，以及设置页入口导航。
///
/// 替身策略：SyncFacade 是 final class 不可伪造，故注入真实门面 +
/// InMemoryAdapter（经 [TestBackendAdapter] 包一层门控/失败注入），
/// provider 装配沿用现有 sync 测试的 overrides 方式。
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/cloud_orphan_cleanup_page.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late InMemoryAdapter inner;
  late TestBackendAdapter adapter;
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('orphan_page_test');
    // 替身适配器先于 pump 创建：测试体在 pump 前布置云端数据/门控。
    inner = InMemoryAdapter();
    adapter = TestBackendAdapter(inner);
  });

  tearDown(() async {
    await tmpDir.delete(recursive: true);
  });

  /// 投喂一个云端正文文件（无 meta 引用 → 孤儿）。
  void seedOrphan(String bookId, int sizeBytes) {
    inner.putContent(bookId, 'epub', List<int>.filled(sizeBytes, 1));
  }

  /// 泵清理页（或任意首页）。[configured] 控制凭据。
  Future<void> pumpPage(
    WidgetTester tester, {
    required bool configured,
    Widget? home,
  }) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    if (configured) {
      await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
      await credentials.save(SecureKeys.webdavPassword, 'app-secret');
      await credentials.save(
        SecureKeys.webdavBaseUrl,
        'https://dav.example.com/',
      );
      await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
    }
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        bookFileStoreProvider.overrideWith(
          (ref) async => BookFileStore(tmpDir),
        ),
        syncAdapterProvider.overrideWithValue(_FixedAdapterProvider(adapter)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: home ?? const CloudOrphanCleanupPage()),
      ),
    );
    // 页面 initState 异步拉清单（含引擎构建的多次 DB 往返）；
    // 页面加载态是无限动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('未配置态：显示未配置提示与去配置入口', (tester) async {
    await pumpPage(tester, configured: false);
    expect(find.text('云端同步未配置'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
  });

  testWidgets('空态：云端没有孤儿文件', (tester) async {
    await pumpPage(tester, configured: true);
    expect(find.text('云端没有孤儿文件'), findsOneWidget);
  });

  testWidgets('列表态：文件名/大小/合计与语义说明可见', (tester) async {
    seedOrphan('01orphanAAA', 700);
    seedOrphan('01orphanBBB', 1500);
    await pumpPage(tester, configured: true);
    expect(find.text('01orphanAAA.epub'), findsOneWidget);
    expect(find.text('01orphanBBB.epub'), findsOneWidget);
    expect(find.text('700 B'), findsOneWidget);
    expect(find.text('1.46 KB'), findsOneWidget);
    expect(find.textContaining('共 2 个文件'), findsOneWidget);
    expect(find.textContaining('合计 2.15 KB'), findsOneWidget);
    // 语义说明（删除不影响任何设备上的书库）。
    expect(find.textContaining('删除不影响任何设备上的书库'), findsOneWidget);
  });

  testWidgets('清单错误态：入口即加载失败 → 错误文案 + 重试恢复', (tester) async {
    adapter.failListing = true;
    await pumpPage(tester, configured: true);
    expect(find.text('孤儿清单获取失败'), findsOneWidget);
    // 500 → ServerError 分类文案（FR-406）。
    expect(find.textContaining('服务异常'), findsOneWidget);

    adapter.failListing = false;
    seedOrphan('01orphanAAA', 700);
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('01orphanAAA.epub'), findsOneWidget);
    expect(find.text('孤儿清单获取失败'), findsNothing);
  });

  testWidgets('单文件删除：确认后从列表移除且合计刷新', (tester) async {
    seedOrphan('01orphanAAA', 700);
    seedOrphan('01orphanBBB', 1500);
    await pumpPage(tester, configured: true);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    // 逐文件确认对话框（docs/04 §7.1 规则 4）。
    expect(find.text('删除孤儿文件？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(inner.books.containsKey('01orphanAAA.epub'), isFalse);
    expect(find.text('01orphanAAA.epub'), findsNothing);
    expect(find.textContaining('共 1 个文件'), findsOneWidget);
    expect(find.text('云端没有孤儿文件'), findsNothing);
  });

  testWidgets('单文件删除失败：行保留 + snackbar 分类原因', (tester) async {
    seedOrphan('01orphanAAA', 700);
    adapter.failOn.add('01orphanAAA.epub');
    await pumpPage(tester, configured: true);

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    // 行保留 + 失败原因（snackbar 与行内红字）。
    expect(find.text('01orphanAAA.epub'), findsOneWidget);
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(find.textContaining('服务异常'), findsWidgets);
    expect(find.textContaining('共 1 个文件'), findsOneWidget);
    // 排空 snackbar 自动消失定时器与退场动画。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('批量清理：进度可见、可暂停、继续后汇总完成', (tester) async {
    seedOrphan('01orphanAAA', 700);
    seedOrphan('01orphanBBB', 700);
    seedOrphan('01orphanCCC', 700);
    // 门控第一个文件的删除：批处理停在"已删 0/3"，给暂停留出窗口。
    final gate = Completer<void>();
    adapter.gates['01orphanAAA.epub'] = gate;
    await pumpPage(tester, configured: true);

    // 总确认（列出数量与合计）。
    await tester.tap(find.text('全部清理'));
    await tester.pumpAndSettle();
    expect(find.textContaining('共 3 个文件'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '全部清理'));
    await tester.pump();

    // 执行中：进度条 + 暂停按钮。
    expect(find.textContaining('已删 0 / 3'), findsOneWidget);
    expect(find.text('暂停'), findsOneWidget);
    await tester.tap(find.text('暂停'));
    gate.complete();
    await tester.pump();
    await tester.pump();
    // 暂停后停止循环（当前文件已删完），按钮变"继续"。
    expect(find.textContaining('已暂停：已删 1 / 3'), findsOneWidget);
    expect(find.text('继续'), findsOneWidget);
    expect(inner.books.length, 2);

    // 继续 → 剩余文件删完 → 汇总。
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(find.text('清理完成'), findsOneWidget);
    expect(find.text('已删除 3 个孤儿文件。'), findsOneWidget);
    expect(inner.books, isEmpty);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('云端没有孤儿文件'), findsOneWidget);
  });

  testWidgets('批量清理进行中：单文件删除按钮禁用', (tester) async {
    seedOrphan('01orphanAAA', 700);
    final gate = Completer<void>();
    adapter.gates['01orphanAAA.epub'] = gate;
    await pumpPage(tester, configured: true);

    await tester.tap(find.text('全部清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '全部清理'));
    await tester.pump();
    // 批处理被门控挂起期间：行内删除按钮应不可用。
    final iconButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.delete_outline),
        matching: find.byType(IconButton),
      ),
    );
    expect(iconButton.onPressed, isNull);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('清理完成'), findsOneWidget);
  });

  testWidgets('设置页入口：已配置点击进入清理页', (tester) async {
    await pumpPage(tester, configured: true, home: const SyncSettingsPage());
    await tester.pumpAndSettle();
    // 入口位于同步维护区（列表较长，先滚动到可见）。
    await tester.scrollUntilVisible(
      find.text('云端孤儿清理'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible 可能停在视口边缘：ensureVisible 完全滚入再点。
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('云端孤儿清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端孤儿清理'));
    // 清理页加载态是无限动画，不能用 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CloudOrphanCleanupPage), findsOneWidget);
    expect(find.text('云端没有孤儿文件'), findsOneWidget);
  });

  testWidgets('设置页入口：未配置点击引导去配置', (tester) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        bookFileStoreProvider.overrideWith(
          (ref) async => BookFileStore(tmpDir),
        ),
        syncAdapterProvider.overrideWithValue(_FixedAdapterProvider(adapter)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const SyncSettingsPage()),
        GoRoute(
          path: '/sync/guide',
          builder: (_, _) => const Scaffold(body: Text('向导-stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    // 未配置时入口仍可见（点击引导去配置）；列表较长，先滚动到可见。
    await tester.scrollUntilVisible(
      find.text('云端孤儿清理'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible 可能停在视口边缘：ensureVisible 完全滚入再点。
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('云端孤儿清理'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('云端孤儿清理'));
    await tester.pumpAndSettle();
    expect(find.text('向导-stub'), findsOneWidget);
  });
}

/// 固定适配器供应（测试注入）。
class _FixedAdapterProvider implements SyncAdapterProvider {
  const _FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}

/// 测试替身：InMemoryAdapter 门面 + 删除门控/失败注入 + 清单失败注入。
final class TestBackendAdapter implements BackendAdapter {
  TestBackendAdapter(this.inner);

  final InMemoryAdapter inner;

  /// deleteBookFile 前挂起的门（测试控制批处理节奏，验证可暂停语义）。
  final Map<String, Completer<void>> gates = {};

  /// deleteBookFile 抛 500 的文件名集合（验证失败保留行）。
  final Set<String> failOn = {};

  /// listBookFiles 抛 500（验证清单错误态与重试）。
  bool failListing = false;

  @override
  BackendKind get kind => inner.kind;

  @override
  Future<void> connect(BackendConfig cfg) => inner.connect(cfg);

  @override
  Future<BackendCapabilities> probeCapabilities() => inner.probeCapabilities();

  @override
  Future<void> ensureLayout() => inner.ensureLayout();

  @override
  Future<String?> readLibraryJson() => inner.readLibraryJson();

  @override
  Future<void> deleteMeta(String bookId) => inner.deleteMeta(bookId);

  @override
  Future<MetaListing> listMetas({String? cursor}) =>
      inner.listMetas(cursor: cursor);

  @override
  Future<List<CloudBookFile>> listBookFiles() async {
    if (failListing) {
      throw const BackendRequestException('清单失败', statusCode: 500);
    }
    return inner.listBookFiles();
  }

  @override
  Future<void> deleteBookFile(String name) async {
    final gate = gates[name];
    if (gate != null) await gate.future;
    if (failOn.contains(name)) {
      throw BackendRequestException('删除失败：$name', statusCode: 500);
    }
    await inner.deleteBookFile(name);
  }

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) =>
      inner.getMeta(bookId, ifNoneMatch: ifNoneMatch);

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) =>
      inner.putMeta(meta, expectedRev: expectedRev);

  @override
  Future<void> putTombstone(BookMeta tombstoned, {required int expectedRev}) =>
      inner.putTombstone(tombstoned, expectedRev: expectedRev);

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) =>
      inner.downloadBook(bookId, startByte: startByte);

  @override
  Future<void> uploadBook(
    String bookId,
    File file,
    String contentHash, {
    bool overwrite = false,
  }) => inner.uploadBook(bookId, file, contentHash, overwrite: overwrite);

  @override
  Future<void> dispose() => inner.dispose();
}
