import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/memory_webdav_server.dart';

/// WebDAV 全流程引擎兼容测试（docs/04 §4 五阶段状态机跑在真实 HTTP 语义上）。
///
/// 与 `sync_engine_test.dart` 的场景矩阵对齐，但适配器为 [WebDavAdapter] +
/// 内存 WebDAV 服务器（六动词/207 multistatus/ETag/Range 全真）：
/// - 验证引擎无需任何 WebDAV 特判即可收敛（stub.rev 由适配器的两级清单
///   供给权威值，见 WebDavAdapter 类注释）；
/// - 覆盖 stub.rev=0 的唯一真实来源（远端 meta 损坏）→ Corruption 跳过
///   不阻塞全库；
/// - 覆盖无 ETag + 无 MOVE 的降级服务器全流程。
void main() {
  late Directory tempDir;
  late MemoryWebDavServer server;
  late WebDavAdapter adapter;
  late InMemorySyncStore store;
  late InMemoryLocalLibrary library;
  late TransferQueue transfer;
  late SyncEngine engine;
  var now = t0;

  const root = '/Apps/SyncReader';
  const backendKey = 'webdav';
  const deviceId = '01DEVLOCAL00000000';
  const deviceName = 'LocalTest';

  Future<void> connectAdapter({MemoryWebDavServer? on}) async {
    final target = on ?? server;
    adapter = WebDavAdapter();
    await adapter.connect(
      BackendConfig(
        kind: BackendKind.webdav,
        baseUrl: target.uri.toString(),
        username: target.username,
        password: target.password,
        rootPath: root,
      ),
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_webdav_compat');
    addTearDown(() => tempDir.delete(recursive: true));
    server = await MemoryWebDavServer.start();
    addTearDown(server.close);
    await connectAdapter();
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

  Future<List<int>> importBook(String bookId, {List<int>? bytes}) async {
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
    return content;
  }

  /// 他端（设备 B）推送 meta 到云端（走同一服务器，模拟另一客户端）。
  Future<void> pushRemoteMeta(BookMeta meta, {required int expectedRev}) async {
    await adapter.putMeta(meta, expectedRev: expectedRev);
  }

  group('五阶段状态机（WebDAV 全真传输）', () {
    test('本端新书上架：meta（tmp→MOVE）+ 正文上云；重跑 inSync 且零 meta GET', () async {
      final content = await importBook(bookIdOf(1));

      final report = await engine.fullSync();
      expect(report.phaseError, isNull, reason: '${report.phaseError}');
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions[bookIdOf(1)], SyncDecision.localNewPush);

      final cloudMeta = BookMeta.fromJsonString(
        utf8.decode(server.fileBytes('$root/meta/${bookIdOf(1)}.json')!),
      );
      expect(cloudMeta.rev, 1);
      expect(server.fileBytes('$root/books/${bookIdOf(1)}.txt'), content);
      expect(server.childrenOf('$root/tmp'), isEmpty, reason: '暂存已 MOVE');
      final state = await store.syncState(bookIdOf(1), backendKey);
      expect(state?.baseRev, 1);

      // 重跑：全部 inSync；无 meta 内容 GET（两级清单热缓存）、无写入。
      server.clearRequestLog();
      final report2 = await engine.fullSync();
      expect(report2.success, isTrue);
      expect(report2.decisions[bookIdOf(1)], SyncDecision.inSync);
      expect(
        server.countRequests(
          (r) => r.startsWith('GET $root/meta/') && r.endsWith('.json'),
        ),
        0,
        reason: '条件请求 + etag→rev 缓存：稳定态零 meta 内容流量',
      );
      expect(server.methodCount('PUT'), 0, reason: '无重写');
    });

    test('第 2 行：本地落后 → 拉取远端 meta（进度覆盖 + baseRev 推进）', () async {
      final bytes = await importBook(bookIdOf(1));
      await engine.fullSync(); // 本端 rev1 上云
      // 他端推进 rev2（进度 80%）。
      await pushRemoteMeta(
        buildMeta(
          bookId: bookIdOf(1),
          rev: 2,
          deviceId: '01DEVB00000000000',
          content: bytes,
          updatedAt: t0.add(const Duration(minutes: 5)),
          progress: buildProgress(
            percent: 0.8,
            updatedAt: t0.add(const Duration(minutes: 5)),
          ),
        ),
        expectedRev: 1,
      );
      server.seedFile('$root/books/${bookIdOf(1)}.txt', bytes);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions[bookIdOf(1)], SyncDecision.pullRemote);
      final localMeta = (await library.book(bookIdOf(1)))!.meta!;
      expect(localMeta.progress?.percent, 0.8, reason: '远端进度覆盖本地');
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 2);
    });

    test('304 命中：清单已见未应用 → 用本地缓存副本完成应用（不重拉）', () async {
      final bytes = await importBook(bookIdOf(1));
      await engine.fullSync();
      final remoteMeta = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB00000000000',
        content: bytes,
        updatedAt: t0.add(const Duration(minutes: 5)),
        progress: buildProgress(
          percent: 0.8,
          updatedAt: t0.add(const Duration(minutes: 5)),
        ),
      );
      await pushRemoteMeta(remoteMeta, expectedRev: 1);
      final etag = (await adapter.listMetas()).stubs[bookIdOf(1)]!.etag!;
      // 中间态（上次同步中断）：state 已缓存 rev2 副本与 etag，baseRev 停在 1。
      await store.saveSyncState(
        BookSyncStateSnapshot(
          bookId: bookIdOf(1),
          backendKey: backendKey,
          baseRev: 1,
          remoteEtag: etag,
          lastSyncedMetaJson: remoteMeta.toJsonString(),
          lastSyncedAt: now,
        ),
      );

      final report = await engine.fullSync();
      expect(report.success, isTrue);
      expect(report.conditionalHits, 1, reason: 'If-None-Match 304 命中');
      expect((await library.book(bookIdOf(1)))!.meta!.progress?.percent, 0.8);
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 2);
    });

    test('占位书按需下载：全量同步不拉正文，downloadContent 校验后落盘', () async {
      final bytes = deterministicBytes(256, 5);
      final meta = buildMeta(bookId: bookIdOf(1), rev: 1, content: bytes);
      await adapter.ensureLayout(); // 首次连接先建布局（引擎外直推的前提）
      await pushRemoteMeta(meta, expectedRev: 0);
      server.seedFile('$root/books/${bookIdOf(1)}.txt', bytes);

      final report = await engine.fullSync();
      expect(report.decisions[bookIdOf(1)], SyncDecision.newFromCloud);
      expect(
        (await library.book(bookIdOf(1)))!.hasLocalContent,
        isFalse,
        reason: '占位书（正文按需，docs/04 §5.4）',
      );

      await engine.downloadContent(bookIdOf(1));
      final path = await library.localContentPath(bookIdOf(1));
      expect(File(path!).readAsBytesSync(), bytes);
    });

    test('冲突：本地 dirty + 远端推进 → 合并推送收敛（totalSeconds 求和）', () async {
      final bytes = await importBook(bookIdOf(1));
      await engine.fullSync(); // rev1 上云，dirty 清零，baseRev=1
      // 公共祖先：rev1（totalSeconds 100）。
      final ancestor = buildMeta(
        bookId: bookIdOf(1),
        rev: 1,
        content: bytes,
        totalSeconds: 100,
      );
      // 他端推进 rev2（percent 50%，totalSeconds 130）。
      await pushRemoteMeta(
        buildMeta(
          bookId: bookIdOf(1),
          rev: 2,
          deviceId: '01DEVB00000000000',
          content: bytes,
          updatedAt: t0.add(const Duration(minutes: 5)),
          progress: buildProgress(
            percent: 0.5,
            updatedAt: t0.add(const Duration(minutes: 5)),
          ),
          totalSeconds: 130,
        ),
        expectedRev: 1,
      );
      // 本地并发修改（percent 70%，totalSeconds 150，updatedAt 更晚）。
      await library.updateProgress(
        bookIdOf(1),
        progress: buildProgress(
          percent: 0.7,
          updatedAt: t0.add(const Duration(minutes: 30)),
        ),
        totalSeconds: 150,
        lastReadAt: t0.add(const Duration(minutes: 30)),
      );
      await store.saveSyncState(
        BookSyncStateSnapshot(
          bookId: bookIdOf(1),
          backendKey: backendKey,
          baseRev: 1,
          lastSyncedMetaJson: ancestor.toJsonString(),
          lastSyncedAt: now,
        ),
      );

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions[bookIdOf(1)], SyncDecision.conflictMerge);
      final cloudMeta = BookMeta.fromJsonString(
        utf8.decode(server.fileBytes('$root/meta/${bookIdOf(1)}.json')!),
      );
      expect(cloudMeta.rev, 3, reason: 'max(2, 2) + 1');
      expect(cloudMeta.progress?.percent, 0.7, reason: '本地 updatedAt 更晚胜');
      expect(cloudMeta.reading.totalSeconds, 180, reason: '150 + 130 − 100');
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 3);
    });

    test('云端 tombstone → 书移出书库视图、正文保留、账本记录', () async {
      final bytes = await importBook(bookIdOf(1));
      await engine.fullSync();
      final tomb = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB00000000000',
        deleted: true,
        deletedAt: t0.add(const Duration(hours: 1)),
        content: bytes,
      );
      await adapter.putTombstone(tomb, expectedRev: 1);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions[bookIdOf(1)], SyncDecision.pullRemote);
      expect(await library.book(bookIdOf(1)), isNull, reason: '书库视图移除');
      expect(
        File(
          '${tempDir.path}/files/books/${bookIdOf(1)}/${bookIdOf(1)}.txt',
        ).existsSync(),
        isTrue,
        reason: '正文保留为游离文件',
      );
      expect(
        (await store.tombstoneLedger()).map((e) => e.bookId),
        contains(bookIdOf(1)),
      );
    });

    test('stub.rev=0 降级路径（远端 meta 损坏）→ Corruption 跳过不阻塞全库', () async {
      await importBook(bookIdOf(1));
      await engine.fullSync(); // b1 上云

      // b2：云端 meta 损坏（PROPFIND 可见但 GET 解析失败 → stub.rev=0）。
      server.seedFile('$root/meta/${bookIdOf(2)}.json', utf8.encode('garbage'));

      final report = await engine.fullSync();
      expect(report.success, isFalse);
      final bad = report.results.singleWhere((r) => r.bookId == bookIdOf(2));
      expect(bad.decision, SyncDecision.newFromCloud);
      expect(bad.error, isA<Corruption>());
      expect(
        report.decisions[bookIdOf(1)],
        SyncDecision.inSync,
        reason: '损坏书不阻塞其余同步',
      );
    });
  });

  group('降级服务器（无 ETag + 无 MOVE）全流程', () {
    setUp(() async {
      await server.close();
      server = await MemoryWebDavServer.start(
        enableEtag: false,
        enableMove: false,
      );
      addTearDown(server.close);
      await connectAdapter();
      transfer = TransferQueue(
        adapter: adapter,
        retryPolicy: const RetryPolicy(),
        delay: (_) async {},
      );
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

    test('上架（直写 + 尺寸校验）→ 他端推进 → 拉取收敛', () async {
      final bytes = await importBook(bookIdOf(1));
      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(server.fileBytes('$root/books/${bookIdOf(1)}.txt'), bytes);
      expect(server.methodCount('MOVE'), 1, reason: '仅能力探测的 MOVE');

      await pushRemoteMeta(
        buildMeta(
          bookId: bookIdOf(1),
          rev: 2,
          deviceId: '01DEVB00000000000',
          content: bytes,
          updatedAt: t0.add(const Duration(minutes: 5)),
          progress: buildProgress(
            percent: 0.9,
            updatedAt: t0.add(const Duration(minutes: 5)),
          ),
        ),
        expectedRev: 1,
      );
      final report2 = await engine.fullSync();
      expect(report2.success, isTrue, reason: '${report2.results}');
      expect(report2.decisions[bookIdOf(1)], SyncDecision.pullRemote);
      expect((await library.book(bookIdOf(1)))!.meta!.progress?.percent, 0.9);
    });
  });
}
