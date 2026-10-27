import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/flaky_adapter.dart';

/// docs/04 §4 五阶段状态机 + §3 直达推送 + §5.3 去重 + §5.4 按需下载 + §7.3 GC。
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

  /// 本地导入一本书（含正文文件），返回内容字节。
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

  /// 在本地与 store 侧登记"已同步至 baseRev"状态。
  Future<void> seedSynced(String bookId, int baseRev) async {
    await library.markSynced(bookId, baseRev: baseRev);
    await store.saveSyncState(
      BookSyncStateSnapshot(
        bookId: bookId,
        backendKey: backendKey,
        baseRev: baseRev,
        lastSyncedMetaJson: null,
        lastSyncedAt: now,
      ),
    );
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_core_engine');
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

  group('五阶段状态机（docs/04 §4）', () {
    test('happy path：本端新书上架（meta+正文推送、syncState/游标落盘），重跑全部 inSync', () async {
      final content = await importBook(bookIdOf(1));

      final report = await engine.fullSync();
      expect(report.phaseError, isNull, reason: '${report.phaseError}');
      expect(report.success, isTrue);
      expect(
        report.results.where((r) => !r.ok),
        isEmpty,
        reason: '${report.results}',
      );

      // 阶段 4：meta 上云（rev=1）。
      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 1);
      expect(cloudMeta.deviceId, deviceId);
      // 阶段 5：正文上云。
      expect(memory.contentOf(bookIdOf(1)), content);
      // 落游标：syncState baseRev + lastSyncedMetaJson + cursor.lastFullSyncAt。
      final state = await store.syncState(bookIdOf(1), backendKey);
      expect(state?.baseRev, 1);
      expect(state?.lastSyncedMetaJson, isNotNull);
      final cursor = await store.cursorSnapshot(backendKey);
      expect(cursor.lastFullSyncAt, now);
      expect(report.bytesUp, content.length);

      // 重跑：全部 inSync，零新增写入（幂等；计数器为累计值，取差值断言）。
      final putsAfterFirst = adapter.putMetaAttempts;
      final uploadsAfterFirst = adapter.uploadAttempts;
      final report2 = await engine.fullSync();
      expect(report2.success, isTrue);
      expect(report2.decisions[bookIdOf(1)], SyncDecision.inSync);
      expect(
        adapter.putMetaAttempts,
        putsAfterFirst,
        reason: '第二次同步不应有任何 meta 写入',
      );
      expect(
        adapter.uploadAttempts,
        uploadsAfterFirst,
        reason: '第二次同步不应有任何正文上传',
      );
    });

    test('第 2 行：本地落后 → 拉取远端 meta 应用（进度覆盖）', () async {
      final bytes = await importBook(bookIdOf(1));
      // 他端推进 rev2（进度 80%）。
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
      await memory.putMeta(remoteMeta, expectedRev: 0);
      memory.putContent(bookIdOf(1), 'txt', bytes);

      // 本地进度 40%，随后登记已同步（清除 dirty → 干净落后）。
      await library.updateProgress(
        bookIdOf(1),
        progress: buildProgress(percent: 0.4),
        totalSeconds: 10,
        lastReadAt: t0,
      );
      await seedSynced(bookIdOf(1), 1);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions[bookIdOf(1)], SyncDecision.pullRemote);
      final localMeta = (await library.book(bookIdOf(1)))!.meta!;
      expect(localMeta.progress?.percent, 0.8, reason: '远端进度覆盖本地');
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 2);
    });

    test('304 跳过：If-None-Match 命中 → 使用本地缓存副本，不重复解析', () async {
      final bytes = await importBook(bookIdOf(1));
      await seedSynced(bookIdOf(1), 1);
      // 他端推进 rev2。
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
      await memory.putMeta(remoteMeta, expectedRev: 0);
      memory.putContent(bookIdOf(1), 'txt', bytes);
      final etag = (await memory.listMetas()).stubs[bookIdOf(1)]!.etag!;
      // 构造"清单已见、但本地尚未应用"的中间态（上次同步中断）：
      // state 已缓存 rev2 副本与 etag，baseRev 仍停留在 1。
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
      expect(memory.conditionalNotModified, 1, reason: '条件请求命中 304');
      expect(report.conditionalHits, 1);
      final localMeta = (await library.book(bookIdOf(1)))!.meta!;
      expect(localMeta.progress?.percent, 0.8, reason: '以缓存副本完成应用（不重拉）');
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 2);
    });

    test('收到 tombstone → 书移出书库视图、正文保留为游离文件、账本记录（docs/04 §7.1.2）', () async {
      final bytes = await importBook(bookIdOf(1));
      await seedSynced(bookIdOf(1), 1);
      final tomb = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB00000000000',
        deleted: true,
        deletedAt: t0.add(const Duration(hours: 1)),
        content: bytes,
      );
      await memory.putTombstone(tomb, expectedRev: 0);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(await library.book(bookIdOf(1)), isNull, reason: '书库视图移除');
      expect(
        File(
          '${tempDir.path}/files/books/${bookIdOf(1)}/${bookIdOf(1)}.txt',
        ).existsSync(),
        isTrue,
        reason: '正文文件保留（游离文件）',
      );
      final ledger = await store.tombstoneLedger();
      expect(ledger.map((e) => e.bookId), contains(bookIdOf(1)));
      expect((await store.syncState(bookIdOf(1), backendKey))?.baseRev, 2);
    });

    test('幂等重放：中途失败（推 meta 网络错误）→ 重跑自动收敛', () async {
      await importBook(bookIdOf(1));
      await importBook(bookIdOf(2), bytes: [4, 5, 6, 7]);
      // 书 2 的第一次 meta 推送注入网络故障（meta 推送不走重试队列）。
      adapter.putMetaFailures[bookIdOf(2)] = [
        () => const BackendRequestException('网络断开'),
      ];

      final report1 = await engine.fullSync();
      expect(report1.success, isFalse);
      final failed = report1.results.where((r) => !r.ok).toList();
      expect(failed.map((r) => r.bookId), [bookIdOf(2)]);
      expect(failed.single.error, isA<NetworkUnreachable>());

      // 故障消除后重跑：无内存残留依赖，自动收敛。
      adapter.putMetaFailures.clear();
      final report2 = await engine.fullSync();
      expect(report2.success, isTrue, reason: '${report2.results}');
      expect(
        BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!).rev,
        greaterThanOrEqualTo(1),
      );
      expect(
        BookMeta.fromJsonString(memory.metas[bookIdOf(2)]!).rev,
        greaterThanOrEqualTo(1),
      );
      expect(memory.contentOf(bookIdOf(1)), [1, 2, 3]);
      expect(memory.contentOf(bookIdOf(2)), [4, 5, 6, 7]);
    });
  });

  group('冲突路径（docs/04 §6.1：RevConflict → 合并 → 重试恰一次）', () {
    /// 云端被他端推进到 rev2；本地基于 baseRev=1 并发修改（保持 dirty）。
    Future<void> seedConflict() async {
      final bytes = await importBook(bookIdOf(1));
      // 先登记 baseRev=1（清 dirty），再写本地并发修改（重新置 dirty）。
      await seedSynced(bookIdOf(1), 1);
      // 云端被他端推进到 rev2（totalSeconds 130，进度 50%）。
      final remoteMeta = buildMeta(
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
      );
      await memory.putMeta(remoteMeta, expectedRev: 0);
      // 本地 dirty：进度 70%（updatedAt 更晚），totalSeconds 150。
      await library.updateProgress(
        bookIdOf(1),
        progress: buildProgress(
          percent: 0.7,
          updatedAt: t0.add(const Duration(minutes: 30)),
        ),
        totalSeconds: 150,
        lastReadAt: t0.add(const Duration(minutes: 30)),
      );
      // 公共祖先：rev1（totalSeconds 100）。
      final ancestor = buildMeta(
        bookId: bookIdOf(1),
        rev: 1,
        content: bytes,
        totalSeconds: 100,
      );
      final state = await store.syncState(bookIdOf(1), backendKey);
      await store.saveSyncState(
        BookSyncStateSnapshot(
          bookId: bookIdOf(1),
          backendKey: backendKey,
          baseRev: 1,
          lastSyncedMetaJson: ancestor.toJsonString(),
          lastSyncedAt: state?.lastSyncedAt ?? now,
        ),
      );
    }

    test(
      'fullSync conflictMerge：预拉远端先合并再推，一次写成功（totalSeconds 求和扣祖先）',
      () async {
        await seedConflict();
        final report = await engine.fullSync();
        expect(report.success, isTrue, reason: '${report.results}');
        expect(report.decisions[bookIdOf(1)], SyncDecision.conflictMerge);
        expect(adapter.putMetaAttempts, 1, reason: '合并先行：写即带新 rev，无冲突往返');
        final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
        expect(cloudMeta.rev, 3, reason: 'max(local 2, remote 2) + 1');
        expect(
          cloudMeta.progress?.percent,
          0.7,
          reason: '本地 updatedAt 更晚 → 本地框架胜',
        );
        expect(
          cloudMeta.reading.totalSeconds,
          180,
          reason: '150 + 130 − 100（公共祖先）',
        );
        final localMeta = (await library.book(bookIdOf(1)))!.meta!;
        expect(localMeta.reading.totalSeconds, 180, reason: '合并结果应用回本地视图');
      },
    );

    test('pushBookMeta 写冲突：拉远端合并 → 以远端 rev 重试恰一次', () async {
      await seedConflict();
      final report = await engine.pushBookMeta(bookIdOf(1));
      expect(report.success, isTrue, reason: '${report.results}');
      expect(adapter.putMetaAttempts, 2, reason: '首次写冲突 + 合并后重试恰一次');
      expect(adapter.listMetasCalls, 0, reason: '直达推送不拉清单（docs/04 §3 第三行）');
      final cloudMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloudMeta.rev, 3);
      expect(cloudMeta.progress?.percent, 0.7);
      expect(cloudMeta.reading.totalSeconds, 180);
    });

    test('合并后重试仍冲突 → ConflictUnresolvable（重试恰一次后放弃）', () async {
      final bytes = await importBook(bookIdOf(1));
      await seedSynced(bookIdOf(1), 1);
      // 云端 rev 与 baseRev 相同（他端无新变更）→ pushLocal 决策。
      await memory.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1, content: bytes),
        expectedRev: 0,
      );
      await library.updateProgress(
        bookIdOf(1),
        progress: buildProgress(percent: 0.7),
        totalSeconds: 10,
        lastReadAt: now,
      );
      // 但写时总被他端抢先（模拟持续并发写入）。
      final racing = AlwaysConflictAdapter(memory);
      final racingEngine = SyncEngine(
        adapter: racing,
        store: store,
        library: library,
        transfer: TransferQueue(
          adapter: racing,
          retryPolicy: const RetryPolicy(),
          delay: (_) async {},
        ),
        now: () => now,
        identity: () async => (deviceId: deviceId, deviceName: deviceName),
        backendKey: backendKey,
      );

      final report = await racingEngine.fullSync();
      final result = report.results.singleWhere((r) => r.bookId == bookIdOf(1));
      expect(result.ok, isFalse);
      expect(result.error, isA<ConflictUnresolvable>());
      expect(racing.putMetaAttempts, 2, reason: '首次 + 重试恰一次');
      // 云端仍是他端写入的 rev1（本机两次写入均被拒）。
      expect(BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!).rev, 1);
      expect(report.phaseError, isNull);
    });
  });

  group('§5.3 哈希去重', () {
    test(
      '本地 bookId 字典序更大 → 并入云端书（adoptCloudBook + 本端 dedupOf tombstone，正文不重传）',
      () async {
        // 云端已有 bookIdOf(2)（hash H）。
        final bytes = [9, 9, 9];
        final hash = contentHashOf(bytes);
        final cloudMeta = buildMeta(
          bookId: bookIdOf(2),
          rev: 1,
          content: bytes,
        );
        await memory.putMeta(cloudMeta, expectedRev: 0);
        memory.putContent(bookIdOf(2), 'txt', bytes);
        // 本地导入 bookIdOf(3)（> b2 字典序）同 hash。
        final (dupFile, _) = await writeTempContent(tempDir, 'dup.txt', bytes);
        await library.importLocalBook(
          bookId: bookIdOf(3),
          title: '同书',
          format: 'txt',
          contentHash: hash,
          sizeBytes: bytes.length,
          sourceFile: dupFile,
        );

        final report = await engine.fullSync();
        expect(report.success, isTrue, reason: '${report.results}');

        // 本端 bookId 写 dedupOf tombstone 并上云。
        final localTomb = BookMeta.fromJsonString(memory.metas[bookIdOf(3)]!);
        expect(localTomb.deleted, isTrue);
        expect(localTomb.dedupOf, bookIdOf(2));
        // 本地条目并入云端书：行挂在 b2 名下，正文文件挪到 b2 目录。
        expect(await library.book(bookIdOf(3)), isNull);
        final mergedRow = (await library.book(bookIdOf(2)))!;
        expect(mergedRow.meta!.book.contentHash, hash);
        expect(await library.localContentPath(bookIdOf(2)), isNotNull);
        // 云端正文不被重传。
        expect(adapter.uploadAttempts, 0);
        // 云端书的 rev 链保留。
        expect((await store.syncState(bookIdOf(2), backendKey))?.baseRev, 1);
      },
    );

    test('本地 bookId 字典序更小 → 保留本地链，云端书覆盖为 dedupOf tombstone，正文照常上传', () async {
      // 云端已有 bookIdOf(3)（hash H）；本地导入 bookIdOf(1)（< b3 字典序）同 hash。
      final bytes = [8, 8, 8];
      final cloudMeta = buildMeta(bookId: bookIdOf(3), rev: 1, content: bytes);
      await memory.putMeta(cloudMeta, expectedRev: 0);
      memory.putContent(bookIdOf(3), 'txt', bytes);
      // 本地导入 bookIdOf(1)（< b3 字典序）同 hash。
      await importBook(bookIdOf(1), bytes: bytes);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');

      // 本地链正常上架 + 正文上传。
      final localMeta = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(localMeta.deleted, isFalse);
      expect(localMeta.rev, 1);
      expect(memory.contentOf(bookIdOf(1)), bytes);
      expect(adapter.uploadAttempts, 1);
      // 云端书覆盖为 dedupOf tombstone。
      final cloudTomb = BookMeta.fromJsonString(memory.metas[bookIdOf(3)]!);
      expect(cloudTomb.deleted, isTrue);
      expect(cloudTomb.dedupOf, bookIdOf(1));
      expect(cloudTomb.rev, 2);
    });
  });

  group('阶段 3 并发与 §5.4 按需下载', () {
    test('PullMetas 并发 2：峰值恰好为 2 且不超过（docs/04 §4 阶段 3）', () async {
      for (var i = 1; i <= 5; i++) {
        final meta = buildMeta(bookId: bookIdOf(i), rev: 1);
        await memory.putMeta(meta, expectedRev: 0);
      }
      adapter.getMetaDelay = const Duration(milliseconds: 5);

      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(report.decisions.values, everyElement(SyncDecision.newFromCloud));
      expect(adapter.getMetaPeak, 2, reason: '并发打满且不超过 2');
      expect(report.pullPeakConcurrency, 2);
      // 占位书：本地无正文，不自动下载（按需，docs/04 §5.4）。
      for (var i = 1; i <= 5; i++) {
        expect((await library.book(bookIdOf(i)))!.hasLocalContent, isFalse);
      }
      expect(adapter.downloadStartBytes, isEmpty);
    });

    test('downloadContent：占位书按需下载 → SHA-256 校验通过 → 转正落盘', () async {
      final bytes = deterministicBytes(200, 5);
      final meta = buildMeta(bookId: bookIdOf(1), rev: 1, content: bytes);
      await memory.putMeta(meta, expectedRev: 0);
      memory.putContent(bookIdOf(1), 'txt', bytes);
      await engine.fullSync(); // 占位上架

      await engine.downloadContent(bookIdOf(1));

      final row = (await library.book(bookIdOf(1)))!;
      expect(row.hasLocalContent, isTrue);
      final path = await library.localContentPath(bookIdOf(1));
      final saved = File(path!);
      expect(saved.readAsBytesSync(), bytes);
    });

    test('downloadContent：云端内容损坏（hash 不符）→ 重试 2 次后抛 Corruption', () async {
      final bytes = deterministicBytes(100, 6);
      final meta = buildMeta(bookId: bookIdOf(1), rev: 1, content: bytes);
      await memory.putMeta(meta, expectedRev: 0);
      memory.putContent(bookIdOf(1), 'txt', [42, 42, 42]); // 云端内容与 meta 不符
      await engine.fullSync();

      await expectLater(
        engine.downloadContent(bookIdOf(1)),
        throwsA(isA<Corruption>()),
      );
      expect(adapter.downloadStartBytes.length, 3, reason: '1 次初始 + 2 次重试');
      expect(
        (await library.book(bookIdOf(1)))!.hasLocalContent,
        isFalse,
        reason: '校验不过不落盘',
      );
    });
  });

  group('游标外场景', () {
    test('cloudMissing：曾有 baseRev 但远端 meta 消失 → 保留本地并标记（不删不推）', () async {
      await importBook(bookIdOf(1));
      await seedSynced(bookIdOf(1), 3);

      final report = await engine.fullSync();
      expect(report.decisions[bookIdOf(1)], SyncDecision.cloudMissing);
      expect(report.success, isTrue);
      expect(library.cloudMissingMarks, 1, reason: '标记云端缺失');
      expect((await library.book(bookIdOf(1)))!, isNotNull, reason: '保留本地');
      expect(memory.metas.containsKey(bookIdOf(1)), isFalse, reason: '不推');
    });

    test('首次连接：ensureLayout 幂等调用一次（library.json 可读）', () async {
      await importBook(bookIdOf(1));
      await engine.fullSync();
      expect(await memory.readLibraryJson(), isNotNull);
    });

    test('换后端重连（同 store 新引擎）：新后端上重建布局并重新上架（resetEngine 闭环）', () async {
      // 设备在旧后端完成过全量（cursor.lastFullSyncAt 已落）。
      await importBook(bookIdOf(1));
      await engine.fullSync();
      expect(await memory.readLibraryJson(), isNotNull);

      // 用户换后端（新空适配器）→ 门面 resetEngine 重建引擎（同 store）。
      final memory2 = InMemoryAdapter();
      await memory2.connect(
        const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://2'),
      );
      final transfer2 = TransferQueue(
        adapter: memory2,
        retryPolicy: const RetryPolicy(),
        delay: (_) async {},
      );
      final engine2 = SyncEngine(
        adapter: memory2,
        store: store,
        library: library,
        transfer: transfer2,
        now: () => now,
        identity: () async => (deviceId: deviceId, deviceName: deviceName),
        backendKey: backendKey,
      );
      final report = await engine2.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      // 新后端上必须重建布局（否则后续 meta PUT 无父目录可写）。
      expect(await memory2.readLibraryJson(), isNotNull);
      // 本地书已有 baseRev 而新后端无 meta → §5.1 第 7b 行：保留本地、
      // 标记云端缺失、不推（防网盘误清后的整库重传）。
      expect(report.decisions[bookIdOf(1)], SyncDecision.cloudMissing);
      expect(library.cloudMissingMarks, 1);
    });
  });

  group('删除同步（docs/04 §7.1）', () {
    test('在线删除：tombstone 上云、账本 pushed、sync_state 更新', () async {
      await importBook(bookIdOf(1));
      await engine.fullSync();
      expect(
        BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!).isTombstone,
        isFalse,
      );

      now = t0.add(const Duration(minutes: 5));
      final report = await engine.deleteBook(bookIdOf(1));
      expect(report.success, isTrue, reason: '${report.results}');

      final cloud = BookMeta.fromJsonString(memory.metas[bookIdOf(1)]!);
      expect(cloud.isTombstone, isTrue);
      expect(cloud.rev, 2);
      expect(cloud.deviceId, deviceId);
      final ledger = await store.tombstoneLedger();
      expect(ledger.single.bookId, bookIdOf(1));
      expect(ledger.single.pushed, isTrue);
      final state = await store.syncState(bookIdOf(1), backendKey);
      expect(state!.baseRev, 2);
      expect(
        BookMeta.fromJsonString(state.lastSyncedMetaJson!).isTombstone,
        isTrue,
        reason: '公共祖先缓存更新为 tombstone',
      );
    });

    test('从未上云的书删除：云端不造条目，账本直接标记已推送', () async {
      await importBook(bookIdOf(2));
      now = t0.add(const Duration(minutes: 5));
      final report = await engine.deleteBook(bookIdOf(2));
      expect(report.success, isTrue, reason: '${report.results}');
      expect(
        memory.metas.containsKey(bookIdOf(2)),
        isFalse,
        reason: '不为云端没见过的书造 tombstone',
      );
      expect((await store.tombstoneLedger()).single.pushed, isTrue);
    });

    test('离线删除 → 账本 pushed=false → 恢复后 fullSync 补推，书不复活', () async {
      await importBook(bookIdOf(3));
      await engine.fullSync();
      now = t0.add(const Duration(minutes: 5));
      adapter.putTombstoneFailures[bookIdOf(3)] = [
        () => const BackendRequestException('网络不可达'),
      ];
      final failReport = await engine.deleteBook(bookIdOf(3));
      expect(failReport.success, isFalse);
      expect(
        (await store.tombstoneLedger()).single.pushed,
        isFalse,
        reason: '离线失败已入账本',
      );

      // 模拟 app softDelete：本地行移除（正文保留不在本测试范围）。
      await library.removeLocalBook(bookIdOf(3));

      // 恢复网络后全量同步：补推 tombstone，且已删书不得被拉回（复活守卫）。
      now = t0.add(const Duration(minutes: 10));
      final report = await engine.fullSync();
      expect(
        BookMeta.fromJsonString(memory.metas[bookIdOf(3)]!).isTombstone,
        isTrue,
        reason: '${report.results}',
      );
      expect((await store.tombstoneLedger()).single.pushed, isTrue);
      expect(await library.book(bookIdOf(3)), isNull, reason: '已删书不得复活为占位');
    });

    test('删除 vs 他端进度更新：后操作优先，删除胜（docs/04 §7.2 对称面）', () async {
      await importBook(bookIdOf(4));
      await engine.fullSync();
      // 他端推更高 rev 的正常 meta（rev=2）。
      await memory.putMeta(
        buildMeta(bookId: bookIdOf(4), rev: 2),
        expectedRev: 1,
      );

      now = t0.add(const Duration(minutes: 5));
      final report = await engine.deleteBook(bookIdOf(4));
      expect(report.success, isTrue, reason: '${report.results}');
      final cloud = BookMeta.fromJsonString(memory.metas[bookIdOf(4)]!);
      expect(cloud.isTombstone, isTrue);
      expect(cloud.rev, 3, reason: 'rev = max(本地 1, 远端 2) + 1，压过他端');
      expect(cloud.updatedAt, now, reason: 'updatedAt = 本端删除时刻（后操作优先）');
    });

    test('补推时云端已是 tombstone（他端已删）→ 幂等标记，不再推送', () async {
      await importBook(bookIdOf(5));
      await engine.fullSync();
      now = t0.add(const Duration(minutes: 5));
      adapter.putTombstoneFailures[bookIdOf(5)] = [
        () => const BackendRequestException('网络不可达'),
      ];
      await engine.deleteBook(bookIdOf(5));
      // 他端也删了：云端已是 tombstone。
      await memory.putTombstone(
        buildMeta(bookId: bookIdOf(5), rev: 9, deleted: true, deletedAt: now),
        expectedRev: 1,
      );
      await library.removeLocalBook(bookIdOf(5));

      now = t0.add(const Duration(minutes: 10));
      final report = await engine.fullSync();
      expect(report.success, isTrue, reason: '${report.results}');
      expect(
        BookMeta.fromJsonString(memory.metas[bookIdOf(5)]!).rev,
        9,
        reason: '他端 tombstone 不被覆盖',
      );
      expect((await store.tombstoneLedger()).single.pushed, isTrue);
    });
  });

  group('tombstone GC（docs/04 §7.3）', () {
    test('账本驱动云端 GC（仅删 > 90 天）；本地账本随 90 天同步清理', () async {
      // 本地账本 = 云端 GC 的驱动源（WebDAV 清单无法感知 tombstone，docs/04 §7.3）。
      // 条目：29 天（保留）、90 天（保留，清理界为"含 90 天"）、91 天（清理）。
      Future<void> ledger(String id, int days) => store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: id,
          deletedAt: t0.subtract(Duration(days: days)),
          pushed: true,
          contentHash: 'sha256:deadbeef',
        ),
      );
      await ledger('ledger-29d', 29);
      await ledger('ledger-90d', 90);
      await ledger('ledger-91d', 91);

      // 云端 tombstone（同时记账本，模拟"他端删除已确认"）：
      // 90 天整（保留，严格 > 90）、91 天（删除）、89 天（保留）。
      Future<void> cloudTomb(String bookId, int days) async {
        final tomb = buildMeta(
          bookId: bookId,
          rev: 2,
          deleted: true,
          deletedAt: t0.subtract(Duration(days: days)),
        );
        await memory.putTombstone(tomb, expectedRev: 0);
        await ledger(bookId, days);
      }

      await cloudTomb(bookIdOf(10), 90);
      await cloudTomb(bookIdOf(11), 91);
      await cloudTomb(bookIdOf(12), 89);

      final report = await engine.gcTombstones();
      expect(report.success, isTrue, reason: '${report.errors}');
      expect(
        report.cloudDeleted,
        1,
        reason: '仅 deletedAt 严格大于 90 天的云端 tombstone',
      );
      expect(memory.metas.containsKey(bookIdOf(11)), isFalse);
      expect(memory.metas.containsKey(bookIdOf(10)), isTrue, reason: '90 天整不删');
      expect(memory.metas.containsKey(bookIdOf(12)), isTrue);

      // 本地清理发生在云端 GC 之后、以 90 天为界（含边界）：
      // ledger-91d 与 bookIdOf(11) 的账本条目被清，其余保留。
      expect(report.localPurged, 2);
      final remaining = (await store.tombstoneLedger()).map((e) => e.bookId);
      expect(
        remaining,
        containsAll(['ledger-29d', 'ledger-90d', bookIdOf(10), bookIdOf(12)]),
      );
      expect(remaining, isNot(contains('ledger-91d')));
      expect(remaining, isNot(contains(bookIdOf(11))));
    });
  });
}
