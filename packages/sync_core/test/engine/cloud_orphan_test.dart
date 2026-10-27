/// 云端孤儿清理（docs/04 §7.1 规则 4，FR-408 的配套手动工具）。
///
/// 判定语义：`books/` 下文件名主干（去掉最后一个 `.ext`）不在 meta 清单
/// bookId 集合中 → 孤儿；**tombstone meta 同样算引用**（删除不删云端正文，
/// tombstoned 书的正文不列为孤儿）。app 层逐文件确认后经
/// [SyncEngine.deleteCloudOrphan] 逐个删除（可暂停），引擎不提供批量删除。
library;

import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/flaky_adapter.dart';

void main() {
  late Directory tempDir;
  late InMemoryAdapter memory;
  late FlakyAdapter adapter;
  late InMemorySyncStore store;
  late InMemoryLocalLibrary library;
  late TransferQueue transfer;
  late SyncEngine engine;
  var now = t0;

  const backendKey = 'webdav';
  const deviceId = '01DEVLOCAL00000000';
  const deviceName = 'LocalTest';

  Future<void> importAndSync(String bookId, {List<int>? bytes}) async {
    final content = bytes ?? [1, 2, 3];
    final (file, hash) = await writeTempContent(
      tempDir,
      '$bookId.src',
      content,
    );
    await library.importLocalBook(
      bookId: bookId,
      title: '书$bookId',
      format: 'txt',
      contentHash: hash,
      sizeBytes: content.length,
      sourceFile: file,
    );
    final report = await engine.fullSync();
    expect(report.success, isTrue, reason: '${report.phaseError}');
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_orphan');
    addTearDown(() => tempDir.delete(recursive: true));
    memory = InMemoryAdapter();
    await memory.connect(
      const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://'),
    );
    adapter = FlakyAdapter(memory);
    store = InMemorySyncStore();
    library = InMemoryLocalLibrary(tempDir);
    transfer = TransferQueue(
      adapter: adapter,
      retryPolicy: const RetryPolicy(),
      delay: (_) async {},
    );
    now = t0;
    engine = SyncEngine(
      adapter: adapter,
      store: store,
      library: library,
      transfer: transfer,
      now: () => now,
      identity: () async => (deviceId: deviceId, deviceName: deviceName),
      backendKey: backendKey,
    );
  });

  group('listCloudOrphans（docs/04 §7.1 规则 4）', () {
    test('有 meta 的书正文不列孤儿', () async {
      await importAndSync(bookIdOf(1));
      final listing = await engine.listCloudOrphans();
      expect(listing.success, isTrue);
      expect(listing.orphans, isEmpty, reason: '${listing.orphans}');
    });

    test('无 meta 引用的 books/* 列为孤儿（文件名主干去扩展名）', () async {
      await importAndSync(bookIdOf(1));
      // 模拟历史删除残留：正文在、meta 不在（GC 后的孤儿）。
      memory.putContent('01ORPHANAAAA00000001', 'epub', [9, 9, 9, 9]);
      memory.putContent('01ORPHANAAAA00000002', 'txt', [7, 7]);

      final listing = await engine.listCloudOrphans();
      expect(listing.success, isTrue);
      expect(listing.orphans, hasLength(2));
      final names = listing.orphans.map((f) => f.name).toSet();
      expect(names, {'01ORPHANAAAA00000001.epub', '01ORPHANAAAA00000002.txt'});
      final epub = listing.orphans.singleWhere(
        (f) => f.name == '01ORPHANAAAA00000001.epub',
      );
      expect(epub.sizeBytes, 4);
    });

    test('tombstone meta 引用的正文不列孤儿（FR-408：删除不删云端正文）', () async {
      await importAndSync(bookIdOf(1));
      // 本端删除：tombstone 上云、正文保留（docs/04 §7.1 规则 1）。
      final report = await engine.deleteBook(bookIdOf(1));
      expect(report.success, isTrue);
      expect(memory.contentOf(bookIdOf(1)), isNotNull, reason: '正文仍在云端');
      expect(memory.metas[bookIdOf(1)], isNotNull, reason: 'tombstone meta 在');

      final listing = await engine.listCloudOrphans();
      expect(listing.success, isTrue);
      expect(listing.orphans, isEmpty, reason: 'tombstone meta 算引用');
    });

    test('清单阶段失败 → error 记入结果且 orphans 为空（引擎永不抛出）', () async {
      await importAndSync(bookIdOf(1));
      // listBookFiles 注入网络故障的专用包装。
      final failing = _FailingListBookFilesAdapter(adapter, memory);
      final orphanEngine = SyncEngine(
        adapter: failing,
        store: store,
        library: library,
        transfer: transfer,
        now: () => now,
        identity: () async => (deviceId: deviceId, deviceName: deviceName),
        backendKey: backendKey,
      );
      final listing = await orphanEngine.listCloudOrphans();
      expect(listing.success, isFalse);
      expect(listing.error, isA<NetworkUnreachable>());
      expect(listing.orphans, isEmpty);
    });
  });

  group('deleteCloudOrphan（逐文件删除入口）', () {
    test('成功：文件从云端消失，返回 null', () async {
      memory.putContent('01ORPHANAAAA00000001', 'txt', [1, 2, 3]);
      final error = await engine.deleteCloudOrphan('01ORPHANAAAA00000001.txt');
      expect(error, isNull);
      expect(memory.books.containsKey('01ORPHANAAAA00000001.txt'), isFalse);
    });

    test('重复删除（404）幂等成功', () async {
      memory.putContent('01ORPHANAAAA00000001', 'txt', [1]);
      expect(
        await engine.deleteCloudOrphan('01ORPHANAAAA00000001.txt'),
        isNull,
      );
      expect(
        await engine.deleteCloudOrphan('01ORPHANAAAA00000001.txt'),
        isNull,
      );
    });

    test('失败路径：适配器异常映射为 SyncError 返回（不抛出），文件保留', () async {
      memory.putContent('01ORPHANAAAA00000001', 'txt', [1, 2, 3]);
      adapter.deleteBookFileFailures.add(
        () => const BackendRequestException('服务端错误', statusCode: 500),
      );
      final error = await engine.deleteCloudOrphan('01ORPHANAAAA00000001.txt');
      expect(error, isA<ServerError>());
      expect(
        memory.books.containsKey('01ORPHANAAAA00000001.txt'),
        isTrue,
        reason: '失败时文件保留，可重试',
      );
      // 恢复后重试成功。
      expect(
        await engine.deleteCloudOrphan('01ORPHANAAAA00000001.txt'),
        isNull,
      );
    });
  });
}

/// listBookFiles 可注入失败的包装（清单失败路径测试用）。
class _FailingListBookFilesAdapter implements BackendAdapter {
  _FailingListBookFilesAdapter(FlakyAdapter inner, InMemoryAdapter base)
    : _inner = inner,
      _base = base;

  final FlakyAdapter _inner;
  final InMemoryAdapter _base;

  @override
  Future<List<CloudBookFile>> listBookFiles() async {
    throw const BackendRequestException('网络异常：listBookFiles');
  }

  @override
  BackendKind get kind => _inner.kind;

  @override
  Future<void> connect(BackendConfig cfg) => _inner.connect(cfg);

  @override
  Future<BackendCapabilities> probeCapabilities() => _inner.probeCapabilities();

  @override
  Future<void> ensureLayout() => _inner.ensureLayout();

  @override
  Future<String?> readLibraryJson() => _inner.readLibraryJson();

  @override
  Future<void> deleteMeta(String bookId) => _inner.deleteMeta(bookId);

  @override
  Future<void> deleteBookFile(String name) => _inner.deleteBookFile(name);

  @override
  Future<MetaListing> listMetas({String? cursor}) => _base.listMetas();

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) =>
      _inner.getMeta(bookId, ifNoneMatch: ifNoneMatch);

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) =>
      _inner.putMeta(meta, expectedRev: expectedRev);

  @override
  Future<void> putTombstone(BookMeta tombstoned, {required int expectedRev}) =>
      _inner.putTombstone(tombstoned, expectedRev: expectedRev);

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) =>
      _inner.downloadBook(bookId, startByte: startByte);

  @override
  Future<void> uploadBook(
    String bookId,
    File file,
    String contentHash, {
    bool overwrite = false,
  }) => _inner.uploadBook(bookId, file, contentHash, overwrite: overwrite);

  @override
  Future<void> dispose() => _inner.dispose();
}
