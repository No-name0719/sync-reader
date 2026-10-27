/// FR-410 文件替换（docs/05 §6 不变式 3 的显式出口，docs/04 §5.3 的补注）。
///
/// 语义冻结：
/// - app 层负责换文件落盘 + [LocalLibrary.updateBookFileInfo] 更新本地行，
///   再调 [SyncEngine.replaceBookContent]（推 meta + overwrite 上传正文）；
/// - 进度字段完全不参与（percent/locator 原样保留）；
/// - 接收端：远端 meta hash ≠ 本地行 hash → **正常下载覆盖**（非损坏）。
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

  final bytesA = [1, 2, 3];
  final bytesB = [9, 8, 7, 6, 5, 4];
  late String hashA;
  late String hashB;

  /// 本地导入 + 首轮同步（meta rev=1、正文 A 上云、syncState baseRev=1）。
  Future<void> importAndSync(String bookId) async {
    final (file, hash) = await writeTempContent(tempDir, '$bookId.src', bytesA);
    hashA = hash;
    await library.importLocalBook(
      bookId: bookId,
      title: '替换书',
      format: 'txt',
      contentHash: hash,
      sizeBytes: bytesA.length,
      sourceFile: file,
    );
    final report = await engine.fullSync();
    expect(report.success, isTrue, reason: '${report.phaseError}');
  }

  /// 模拟 app 层替换动作：新文件覆盖本地正文路径 + updateBookFileInfo。
  Future<void> replaceLocalFile(String bookId) async {
    hashB = contentHashOf(bytesB);
    final path = await library.localContentPath(bookId);
    expect(path, isNotNull);
    await File(path!).writeAsBytes(bytesB);
    await library.updateBookFileInfo(
      bookId,
      fileName: '替换书-v2.txt',
      contentHash: hashB,
      sizeBytes: bytesB.length,
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_replace');
    addTearDown(() => tempDir.delete(recursive: true));
    hashA = contentHashOf(bytesA);
    hashB = contentHashOf(bytesB);
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

  group('replaceBookContent（FR-410）', () {
    test('替换成功：meta rev+1 携带新 hash、syncState 更新、远端正文变为新内容', () async {
      await importAndSync(bookIdOf(1));
      await replaceLocalFile(bookIdOf(1));

      final report = await engine.replaceBookContent(bookIdOf(1));
      expect(report.success, isTrue, reason: '${report.results}');

      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 2, reason: 'rev 在 baseRev 之上 +1');
      expect(cloudMeta.book.contentHash, hashB, reason: 'meta 携带新 hash');
      expect(cloudMeta.book.sizeBytes, bytesB.length);
      // 进度字段原样保留（未读过为 null，不因替换而变化）。
      expect(cloudMeta.progress, isNull);
      // 远端正文已是新字节。
      expect(memory.contentOf(bookIdOf(1)), bytesB);
      // syncState 收敛到 rev=2，公共祖先缓存即新 meta。
      final state = await store.syncState(bookIdOf(1), backendKey);
      expect(state?.baseRev, 2);
      expect(state?.lastSyncedMetaJson, contains(hashB));
      // 本地行 dirty 已被推送流程清除 → 下轮 fullSync inSync、零重复上传。
      final uploadsAfterReplace = adapter.uploadAttempts;
      final report2 = await engine.fullSync();
      expect(report2.decisions[bookIdOf(1)], SyncDecision.inSync);
      expect(adapter.uploadAttempts, uploadsAfterReplace);
    });

    test('无本地书 / 占位书（无本地正文）→ Corruption 记入 report，不抛出', () async {
      // 本地书库不存在该书。
      final r1 = await engine.replaceBookContent('01NOTEXIST0000000001');
      expect(r1.success, isFalse);
      expect(r1.results.single.error, isA<Corruption>());

      // 占位书：云端有、本地无正文文件。
      await memory.ensureLayout();
      await memory.putMeta(
        buildMeta(
          bookId: bookIdOf(2),
          rev: 1,
          content: bytesA,
          contentHash: hashA,
          sizeBytes: bytesA.length,
        ),
        expectedRev: 0,
      );
      memory.putContent(bookIdOf(2), 'txt', bytesA);
      final sync = await engine.fullSync();
      expect(sync.success, isTrue);
      expect(await library.localContentPath(bookIdOf(2)), isNull);

      final r2 = await engine.replaceBookContent(bookIdOf(2));
      expect(r2.success, isFalse);
      expect(r2.results.single.error, isA<Corruption>());
      expect(r2.results.single.error!.message, contains('缺失'));
    });

    test('远端并发修改 → RevConflict 合并后重试恰一次，替换内容照常上传', () async {
      // 本端先读到 50%（updatedAt 更晚 → 合并本端胜出，book 信息取本端新 hash）。
      final (file, hash) = await writeTempContent(tempDir, 'c.src', bytesA);
      await library.importLocalBook(
        bookId: bookIdOf(1),
        title: '替换书',
        format: 'txt',
        contentHash: hash,
        sizeBytes: bytesA.length,
        sourceFile: file,
      );
      await library.updateProgress(
        bookIdOf(1),
        progress: buildProgress(
          percent: 0.5,
          updatedAt: t0.add(const Duration(hours: 2)),
        ),
        totalSeconds: 100,
        lastReadAt: t0.add(const Duration(hours: 2)),
      );
      final sync = await engine.fullSync();
      expect(sync.success, isTrue);

      // 他端并发推 rev=2（进度更新，updatedAt 更早）。
      await adapter.putMeta(
        buildMeta(
          bookId: bookIdOf(1),
          rev: 2,
          updatedAt: t0.add(const Duration(hours: 1)),
          progress: buildProgress(
            percent: 0.7,
            updatedAt: t0.add(const Duration(hours: 1)),
          ),
          content: bytesA,
          contentHash: hashA,
          sizeBytes: bytesA.length,
        ),
        expectedRev: 1,
      );

      await replaceLocalFile(bookIdOf(1));
      final report = await engine.replaceBookContent(bookIdOf(1));
      expect(report.success, isTrue, reason: '${report.results}');

      // 合并结果 rev = max(2,2)+1 = 3；本端胜出 → book 指征为本端新 hash。
      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 3);
      expect(cloudMeta.book.contentHash, hashB);
      expect(memory.contentOf(bookIdOf(1)), bytesB);
      final state = await store.syncState(bookIdOf(1), backendKey);
      expect(state?.baseRev, 3);
    });

    test('meta 推送失败（冲突不可解）→ 跳过正文上传，云端保持一致', () async {
      await importAndSync(bookIdOf(1));
      await replaceLocalFile(bookIdOf(1));
      // 他端持续并发写入：合并重试仍冲突。
      final conflicting = AlwaysConflictAdapter(memory);
      final conflictEngine = SyncEngine(
        adapter: conflicting,
        store: store,
        library: library,
        transfer: transfer,
        now: () => now,
        identity: () async => (deviceId: deviceId, deviceName: deviceName),
        backendKey: backendKey,
      );
      final report = await conflictEngine.replaceBookContent(bookIdOf(1));
      expect(report.success, isFalse);
      expect(report.results.single.error, isA<ConflictUnresolvable>());
      // 云端 meta 与正文都未动（无"新正文 + 旧 meta"不一致窗口）。
      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 1);
      expect(cloudMeta.book.contentHash, hashA);
      expect(memory.contentOf(bookIdOf(1)), bytesA);
    });

    test('正文上传离线失败 → meta 已推、错误记入 report；重试后收敛', () async {
      await importAndSync(bookIdOf(1));
      await replaceLocalFile(bookIdOf(1));

      // 注入上传网络故障（maxNetworkAttempts=1 → 立即放弃）。
      final offlineTransfer = TransferQueue(
        adapter: adapter,
        retryPolicy: const RetryPolicy(maxNetworkAttempts: 1),
        delay: (_) async {},
      );
      final offlineEngine = SyncEngine(
        adapter: adapter,
        store: store,
        library: library,
        transfer: offlineTransfer,
        now: () => now,
        identity: () async => (deviceId: deviceId, deviceName: deviceName),
        backendKey: backendKey,
      );
      adapter.uploadFailures.add(() => const BackendRequestException('断网'));

      final report = await offlineEngine.replaceBookContent(bookIdOf(1));
      expect(report.success, isFalse);
      final okResults = report.results.where((r) => r.ok).toList();
      final badResults = report.results.where((r) => !r.ok).toList();
      expect(okResults, hasLength(1), reason: 'meta 推送成功');
      expect(badResults.single.error, isA<NetworkUnreachable>());

      // 收敛状态明确：meta 已上云（rev=2、新 hash），正文仍是旧内容。
      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 2);
      expect(cloudMeta.book.contentHash, hashB);
      expect(memory.contentOf(bookIdOf(1)), bytesA, reason: '上传失败正文未换');

      // 重试 replaceBookContent：再推 meta（rev=3）并成功上传新正文。
      final report2 = await engine.replaceBookContent(bookIdOf(1));
      expect(report2.success, isTrue, reason: '${report2.results}');
      expect(memory.contentOf(bookIdOf(1)), bytesB);
      final cloudMeta2 = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta2.rev, 3);
      expect(cloudMeta2.book.contentHash, hashB);
    });

    test('updateBookFileInfo：书不存在抛 StateError；仅更新非 null 列', () async {
      await importAndSync(bookIdOf(1));
      // 仅更新 sizeBytes：title/hash 等保持不变。
      await library.updateBookFileInfo(bookIdOf(1), sizeBytes: 999);
      final snap = await library.book(bookIdOf(1));
      expect(snap?.meta?.book.sizeBytes, 999);
      expect(snap?.meta?.book.contentHash, hashA);
      expect(snap?.meta?.book.title, '替换书');

      expect(
        () => library.updateBookFileInfo('01NOTEXIST0000000001', sizeBytes: 1),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('FR-410 接收端：hash 变化 → 正常下载覆盖（非损坏）', () {
    late Directory tempDirB;
    late InMemorySyncStore storeB;
    late InMemoryLocalLibrary libraryB;

    setUp(() async {
      tempDirB = await Directory.systemTemp.createTemp('sync_core_recv_b');
      addTearDown(() => tempDirB.delete(recursive: true));
      storeB = InMemorySyncStore();
      libraryB = InMemoryLocalLibrary(tempDirB);
    });

    SyncEngine buildEngineForB({required bool autoDownload}) {
      final t = TransferQueue(
        adapter: adapter,
        retryPolicy: const RetryPolicy(),
        delay: (_) async {},
      );
      return SyncEngine(
        adapter: adapter,
        store: storeB,
        library: libraryB,
        transfer: t,
        now: () => now,
        identity: () async =>
            (deviceId: '01DEVBBBB0000000000', deviceName: '设备B'),
        backendKey: backendKey,
        autoDownloadContent: autoDownload,
      );
    }

    /// 前置：A 上架（rev1/正文A）→ B 同步并持有旧正文。
    Future<void> seedBothDevices() async {
      await importAndSync(bookIdOf(1));
      final engineB = buildEngineForB(autoDownload: true);
      final reportB = await engineB.fullSync();
      expect(reportB.success, isTrue);
      final pathB = await libraryB.localContentPath(bookIdOf(1));
      expect(await File(pathB!).readAsBytes(), bytesA);
    }

    test('autoDownloadContent：fullSync 检出替换 → 自动下载覆盖本地旧文件', () async {
      await seedBothDevices();
      // A 端替换文件并推送。
      await replaceLocalFile(bookIdOf(1));
      final reportA = await engine.replaceBookContent(bookIdOf(1));
      expect(reportA.success, isTrue);

      // B 端全量同步：pullRemote 检出 meta hash ≠ 本地 hash → 自动下载覆盖。
      adapter.downloadStartBytes.clear();
      final uploadsBeforeB = adapter.uploadAttempts;
      final engineB = buildEngineForB(autoDownload: true);
      final reportB = await engineB.fullSync();
      expect(reportB.success, isTrue, reason: '${reportB.results}');
      expect(reportB.decisions[bookIdOf(1)], SyncDecision.pullRemote);
      expect(adapter.downloadStartBytes, hasLength(1), reason: '替换正文恰好下载一次');

      final pathB = await libraryB.localContentPath(bookIdOf(1));
      expect(await File(pathB!).readAsBytes(), bytesB, reason: '本地旧文件已被新正文覆盖');
      final snapB = await libraryB.book(bookIdOf(1));
      expect(snapB?.meta?.book.contentHash, hashB);
      expect(adapter.uploadAttempts, uploadsBeforeB, reason: '接收端不上传');

      // 再跑一轮：inSync、零下载（无重复下载）。
      final downloads = adapter.downloadStartBytes.length;
      final reportB2 = await engineB.fullSync();
      expect(reportB2.decisions[bookIdOf(1)], SyncDecision.inSync);
      expect(adapter.downloadStartBytes.length, downloads);
    });

    test('手动按需：拉到替换 meta 后 downloadContent 覆盖旧文件（校验用新 meta hash）', () async {
      await seedBothDevices();
      await replaceLocalFile(bookIdOf(1));
      expect((await engine.replaceBookContent(bookIdOf(1))).success, isTrue);

      // B 端默认不自动下载：meta 应用后本地行指向新 hash，文件仍是旧字节。
      final engineB = buildEngineForB(autoDownload: false);
      final reportB = await engineB.fullSync();
      expect(reportB.success, isTrue);
      final pathB = await libraryB.localContentPath(bookIdOf(1));
      expect(await File(pathB!).readAsBytes(), bytesA, reason: '旧文件暂存，等待按需下载');

      // 用户打开书 → 按需下载：校验用应用后的 meta hash，正常覆盖（非损坏）。
      await engineB.downloadContent(bookIdOf(1));
      expect(await File(pathB).readAsBytes(), bytesB);
    });
  });
}
