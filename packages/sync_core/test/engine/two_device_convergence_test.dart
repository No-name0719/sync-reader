/// 双端收敛预演（FR-404 核心验收的自动化替身，docs/04 §6.4 场景表）。
///
/// 两套 [SyncEngine]（各自 [InMemorySyncStore] + [InMemoryLocalLibrary]，
/// 共享同一 [InMemoryAdapter] 后端）模拟两台设备：
///
/// 1. 进度收敛：A 导入读到 40% → 同步 → B 拉到占位并下载正文 → B 离线读到
///    75%（直接改本地进度标 dirty）→ A 也读到 65% 标 dirty → 双端恢复后各
///    fullSync → 两端 percent 收敛到 75%、`totalSeconds` 按求和特例合并、
///    胜者由 (rev, updatedAt, deviceId) 定序唯一确定；再各跑一轮全量保持
///    inSync（定序稳定，不翻转）。
/// 2. tombstone 双端传播：A 删除（docs/04 §7.1 第 1 条的端上约定：写
///    tombstone 上云 + 本端移出书库视图）→ 同步 → B 同步后书从书库视图消失、
///    B 的本地正文文件保留（游离语义，§7.1 第 2 条）。
///
/// 注：LocalLibrary/引擎不设"本地删除"API——删除的上半段（写 tombstone +
/// 移出视图 + 记账本）属端上应用层约定（app 侧 softDelete + tombstone 推送），
/// 引擎只负责 tombstone 作为普通 meta 的定序与传播，故用例按 §7.1 原语模拟。
library;

import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  late Directory tempDirA;
  late Directory tempDirB;
  late InMemoryAdapter cloud;
  late InMemorySyncStore storeA;
  late InMemorySyncStore storeB;
  late InMemoryLocalLibrary libraryA;
  late InMemoryLocalLibrary libraryB;
  late SyncEngine engineA;
  late SyncEngine engineB;

  const backendKey = 'webdav';
  const deviceA = '01DEVAAAA0000000000';
  const deviceB = '01DEVBBBB0000000000';

  var now = t0;

  SyncEngine buildEngine({
    required BackendAdapter adapter,
    required InMemorySyncStore store,
    required InMemoryLocalLibrary library,
    required String deviceId,
    required String deviceName,
  }) {
    final transfer = TransferQueue(
      adapter: adapter,
      retryPolicy: const RetryPolicy(),
      delay: (_) async {},
    );
    return SyncEngine(
      adapter: adapter,
      store: store,
      library: library,
      transfer: transfer,
      now: () => now,
      identity: () async => (deviceId: deviceId, deviceName: deviceName),
      backendKey: backendKey,
    );
  }

  setUp(() async {
    tempDirA = await Directory.systemTemp.createTemp('sync_two_dev_a');
    tempDirB = await Directory.systemTemp.createTemp('sync_two_dev_b');
    addTearDown(() => tempDirA.delete(recursive: true));
    addTearDown(() => tempDirB.delete(recursive: true));
    cloud = InMemoryAdapter();
    await cloud.connect(
      const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://cloud'),
    );
    storeA = InMemorySyncStore();
    storeB = InMemorySyncStore();
    libraryA = InMemoryLocalLibrary(tempDirA);
    libraryB = InMemoryLocalLibrary(tempDirB);
    engineA = buildEngine(
      adapter: cloud,
      store: storeA,
      library: libraryA,
      deviceId: deviceA,
      deviceName: '设备A',
    );
    engineB = buildEngine(
      adapter: cloud,
      store: storeB,
      library: libraryB,
      deviceId: deviceB,
      deviceName: '设备B',
    );
    now = t0;
  });

  Future<void> importOn(
    InMemoryLocalLibrary library,
    String bookId, {
    List<int> content = const [1, 2, 3],
  }) async {
    final (file, hash) = await writeTempContent(
      tempDirA,
      '$bookId.src',
      content,
    );
    await library.importLocalBook(
      bookId: bookId,
      title: '双端书',
      format: 'txt',
      contentHash: hash,
      sizeBytes: content.length,
      sourceFile: file,
    );
  }

  /// 模拟本机阅读产生进度（dirty 置位，docs/04 §3 触发时机 3 的前置）。
  Future<void> readOn(
    InMemoryLocalLibrary library,
    String bookId, {
    required double percent,
    required int totalSeconds,
    required DateTime at,
  }) {
    return library.updateProgress(
      bookId,
      progress: ReadingProgress(
        locator: RawLocator(ratio: percent),
        percent: percent,
        updatedAt: at,
      ),
      totalSeconds: totalSeconds,
      lastReadAt: at,
    );
  }

  test('双端并发进度：收敛到 updatedAt 更晚的 75%，totalSeconds 求和，定序稳定', () async {
    final bookId = bookIdOf(1);

    // ── A 导入并读到 40% → 同步上架（meta rev1 + 正文）──
    await importOn(libraryA, bookId);
    await readOn(
      libraryA,
      bookId,
      percent: 0.40,
      totalSeconds: 100,
      at: t0.add(const Duration(hours: 1)),
    );
    now = t0.add(const Duration(hours: 1, minutes: 5));
    final reportA1 = await engineA.fullSync();
    expect(reportA1.decisions[bookId], SyncDecision.localNewPush);
    expect(reportA1.success, isTrue, reason: '${reportA1.results}');

    // ── B 首次同步：拉到占位书（正文按需）──
    now = now.add(const Duration(minutes: 1));
    final reportB1 = await engineB.fullSync();
    expect(reportB1.decisions[bookId], SyncDecision.newFromCloud);
    final placeholderOnB = await libraryB.book(bookId);
    expect(placeholderOnB, isNotNull);
    expect(placeholderOnB!.hasLocalContent, isFalse, reason: '占位书');
    expect(placeholderOnB.meta!.progress!.percent, 0.40);

    // B 点开占位书 → 按需下载正文（docs/04 §5.4）。
    await engineB.downloadContent(bookId);
    final downloadedOnB = await libraryB.localContentPath(bookId);
    expect(downloadedOnB, isNotNull);
    expect(File(downloadedOnB!).readAsBytesSync(), [1, 2, 3]);

    // ── B 离线读到 75%（直接改本地进度标 dirty）──
    final t75 = t0.add(const Duration(hours: 3));
    await readOn(libraryB, bookId, percent: 0.75, totalSeconds: 150, at: t75);

    // ── A 在线读到 65% 并同步（先上云：rev2, percent 65%）──
    final t65 = t0.add(const Duration(hours: 2));
    await readOn(libraryA, bookId, percent: 0.65, totalSeconds: 130, at: t65);
    now = t0.add(const Duration(hours: 3, minutes: 1));
    final reportA2 = await engineA.fullSync();
    expect(reportA2.decisions[bookId], SyncDecision.pushLocal);
    expect(reportA2.success, isTrue, reason: '${reportA2.results}');
    expect((await cloud.getMeta(bookId))!.progress!.percent, 0.65);

    // ── B 恢复在线 fullSync：冲突合并（B 的 75% updatedAt 更晚 → 胜出）──
    now = t0.add(const Duration(hours: 3, minutes: 2));
    final reportB2 = await engineB.fullSync();
    expect(reportB2.decisions[bookId], SyncDecision.conflictMerge);
    expect(reportB2.success, isTrue, reason: '${reportB2.results}');

    // 云端收敛：percent 75%、totalSeconds 求和特例（150 + 130 − 祖先 100）、
    // 合并结果由 B 作为新写端推送（rev = max(2,2)+1 = 3）。
    final cloudMeta = await cloud.getMeta(bookId);
    expect(cloudMeta!.progress!.percent, 0.75);
    expect(cloudMeta.reading.totalSeconds, 180);
    expect(cloudMeta.rev, 3);
    expect(cloudMeta.deviceId, deviceB, reason: '定序稳定：胜端作为写端');

    // ── A 再 fullSync：落后于 rev3 → 拉取收敛 ──
    now = now.add(const Duration(minutes: 1));
    final reportA3 = await engineA.fullSync();
    expect(reportA3.decisions[bookId], SyncDecision.pullRemote);
    expect(reportA3.success, isTrue, reason: '${reportA3.results}');

    // 两端视图收敛一致（percent/时长），且与云端同源（lastSyncedMetaJson 相同）。
    for (final library in [libraryA, libraryB]) {
      final snap = await library.book(bookId);
      expect(snap!.meta!.progress!.percent, 0.75);
      expect(snap.meta!.reading.totalSeconds, 180);
      expect(snap.dirty, isFalse);
    }
    final syncedA = await storeA.syncState(bookId, backendKey);
    final syncedB = await storeB.syncState(bookId, backendKey);
    expect(syncedA!.lastSyncedMetaJson, syncedB!.lastSyncedMetaJson);
    expect(syncedA.baseRev, 3);
    expect(syncedB.baseRev, 3);

    // ── 定序稳定：双端再各跑一轮全量，全部 inSync，无翻转 ──
    now = now.add(const Duration(minutes: 1));
    final reportA4 = await engineA.fullSync();
    final reportB3 = await engineB.fullSync();
    expect(reportA4.decisions[bookId], SyncDecision.inSync);
    expect(reportB3.decisions[bookId], SyncDecision.inSync);
    expect((await libraryA.book(bookId))!.meta!.progress!.percent, 0.75);
    expect((await libraryB.book(bookId))!.meta!.progress!.percent, 0.75);
  });

  test('tombstone 双端传播：A 删除 → B 同步后书消失、本地正文保留为游离文件', () async {
    final bookId = bookIdOf(2);

    // A 上架 → B 拉占位并下载正文（B 本地有文件）。
    await importOn(libraryA, bookId);
    now = t0.add(const Duration(minutes: 1));
    expect((await engineA.fullSync()).success, isTrue);
    now = now.add(const Duration(minutes: 1));
    expect((await engineB.fullSync()).success, isTrue);
    await engineB.downloadContent(bookId);
    final contentOnB = await libraryB.localContentPath(bookId);
    expect(contentOnB, isNotNull);

    // A 端删除（docs/04 §7.1 第 1 条的端上约定）：
    // rev = 本端计数器下一个；tombstone 上云（expectedRev=云端当前 rev）；
    // 本端移出书库视图（正文留盘转游离）；记 tombstone 账本。
    final cloudMeta = (await cloud.getMeta(bookId))!;
    final rev = await storeA.nextRev(bookId, atLeast: cloudMeta.rev + 1);
    final tomb = cloudMeta.toTombstone(
      deletedAt: t0.add(const Duration(hours: 4)),
      deviceId: deviceA,
      deviceName: '设备A',
    );
    await cloud.putTombstone(tomb.withRev(rev), expectedRev: cloudMeta.rev);
    await libraryA.applyRemoteMeta(tomb.withRev(rev));
    await storeA.recordTombstone(
      TombstoneLedgerEntry(
        bookId: bookId,
        deletedAt: t0.add(const Duration(hours: 4)),
        pushed: true,
        contentHash: cloudMeta.book.contentHash,
      ),
    );
    expect(await libraryA.book(bookId), isNull, reason: 'A 端移出书库视图');

    // A 同步：本地无 + 云端 tombstone → 无操作（不复活、不误推）。
    now = t0.add(const Duration(hours: 4, minutes: 1));
    final reportA = await engineA.fullSync();
    expect(reportA.decisions[bookId], SyncDecision.cloudTombstoneNoLocal);
    expect(reportA.success, isTrue, reason: '${reportA.results}');

    // B 同步：落后于 tombstone → 拉取并按删除应用。
    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.decisions[bookId], SyncDecision.pullRemote);
    expect(reportB.success, isTrue, reason: '${reportB.results}');

    // B 端：书从书库视图消失；正文文件保留（游离语义，docs/04 §7.1 第 2 条）；
    // 账本记录"删除已确认"。
    expect(await libraryB.book(bookId), isNull);
    expect(File(contentOnB!).existsSync(), isTrue, reason: '永不自动删正文');
    final ledgerB = await storeB.tombstoneLedger();
    expect(ledgerB.map((e) => e.bookId), contains(bookId));

    // A 的正文同样留盘（本端删除 = 移入游离区，不真正删文件；行已移除，
    // 游离文件只能按目录约定在盘上确认）。
    final orphanOnA = File('${tempDirA.path}/files/books/$bookId/$bookId.txt');
    expect(orphanOnA.existsSync(), isTrue, reason: '永不自动删正文');
  });
}

/// BookMeta.withRev：测试内固定 rev 的 tombstone 变体（引擎内部同款语义）。
extension _BookMetaRevX on BookMeta {
  BookMeta withRev(int rev) => BookMeta(
    schemaVersion: schemaVersion,
    bookId: bookId,
    rev: rev,
    deviceId: deviceId,
    deviceName: deviceName,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deleted: deleted,
    deletedAt: deletedAt,
    dedupOf: dedupOf,
    book: book,
    progress: progress,
    reading: reading,
    annotations: annotations,
    extra: extra,
  );
}
