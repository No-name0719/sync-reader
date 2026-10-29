import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// 「从云端移除」（docs/10 §4.7c / §4.8）：只删云端 meta 副本，
/// **不写 tombstone、不删本地书行、不动本地正文**。
///
/// 与 [SyncEngine.deleteBook] 的语义边界是本用例的核心断言。
void main() {
  late Directory tempDir;
  late InMemoryAdapter memory;
  late InMemorySyncStore store;
  late InMemoryLocalLibrary library;
  late TransferQueue transfer;
  late SyncEngine engine;
  var now = t0;

  const backendKey = 'webdav';
  const deviceId = '01DEVLOCAL00000000';
  const deviceName = 'LocalTest';

  /// 导入一本书并上架（云端有 meta + 正文）。
  Future<String> importAndPush(String bookId) async {
    final content = [1, 2, 3];
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
    expect(report.success, isTrue, reason: '${report.results}');
    expect(memory.metas.containsKey(bookId), isTrue);
    return hash;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_remove_cloud');
    addTearDown(() => tempDir.delete(recursive: true));
    memory = InMemoryAdapter();
    await memory.connect(
      const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://'),
    );
    store = InMemorySyncStore();
    library = InMemoryLocalLibrary(tempDir);
    transfer = TransferQueue(
      adapter: memory,
      retryPolicy: const RetryPolicy(),
      delay: (_) async {},
    );
    now = t0;
    engine = SyncEngine(
      adapter: memory,
      store: store,
      library: library,
      transfer: transfer,
      now: () => now,
      identity: () async => (deviceId: deviceId, deviceName: deviceName),
      backendKey: backendKey,
    );
  });

  test('removeCloudCopy：删云端 meta，但不写 tombstone、不删本地行/正文', () async {
    final bookId = bookIdOf(1);
    final hash = await importAndPush(bookId);
    final stateBefore = await store.syncState(bookId, backendKey);
    expect(stateBefore, isNotNull);
    expect(stateBefore!.baseRev, greaterThanOrEqualTo(1));

    // 执行「从云端移除」。
    await engine.removeCloudCopy(bookId);

    // 云端 meta 消失。
    expect(memory.metas.containsKey(bookId), isFalse);
    expect(memory.deleteMetaCalls, 1);
    // **不写 tombstone**：本地墓碑账本为空。
    expect(await store.tombstoneLedger(), isEmpty);
    // **不删本地书行**：快照仍在。
    final snap = await library.book(bookId);
    expect(snap, isNotNull);
    expect(snap!.meta!.book.contentHash, hash);
    expect(snap.hasLocalContent, isTrue);
    // **本地正文文件不动**。
    final contentPath = await library.localContentPath(bookId);
    expect(contentPath, isNotNull);
    expect(File(contentPath!).existsSync(), isTrue);
    // **baseRev 保持不变**（这正是让各端后续落 diff 第 7b 行「云端缺失」的
    // 关键：保留本地、不再上传）。
    final stateAfter = await store.syncState(bookId, backendKey);
    expect(stateAfter, isNotNull);
    expect(stateAfter!.baseRev, stateBefore.baseRev);
  });

  test('removeCloudCopy 后全量同步：落第 7b 行（云端缺失），不重新上传', () async {
    final bookId = bookIdOf(2);
    await importAndPush(bookId);
    await engine.removeCloudCopy(bookId);

    final report = await engine.fullSync();
    expect(report.success, isTrue, reason: '${report.results}');
    expect(report.decisions[bookId], SyncDecision.cloudMissing);
    // 云端仍无此书（没被重新推上去）。
    expect(memory.metas.containsKey(bookId), isFalse);
    // 本地正文仍在。
    final contentPath = await library.localContentPath(bookId);
    expect(contentPath, isNotNull);
    expect(File(contentPath!).existsSync(), isTrue);
  });

  test('removeCloudCopy 与 deleteBook 的语义边界不同（后者写墓碑）', () async {
    final bookId = bookIdOf(3);
    await importAndPush(bookId);

    await engine.removeCloudCopy(bookId);
    expect(await store.tombstoneLedger(), isEmpty, reason: '不写墓碑');

    // 对照：deleteBook 会写墓碑并推 tombstone。
    final otherId = bookIdOf(4);
    await importAndPush(otherId);
    final report = await engine.deleteBook(otherId);
    expect(report.success, isTrue);
    final ledger = await store.tombstoneLedger();
    expect(ledger.map((e) => e.bookId), contains(otherId));
    expect(
      BookMeta.fromJsonString(memory.metas[otherId]!).isTombstone,
      isTrue,
    );
  });
}
