/// 分组云端同步的双端收敛预演（FR-107 云端同步，docs/05 §2.1）。
///
/// 两套 [SyncEngine]（各自 [InMemorySyncStore] + [InMemoryLocalLibrary]，
/// 共享同一 [InMemoryAdapter] 后端）模拟两台设备，覆盖验收契约：
/// 1. A 端新建分组 → 同步 → B 端出现同名分组；
/// 2. A 端重命名分组 → B 端同步后分组名更新；
/// 3. A 端把书拖进分组 → B 端同步后该书也在该分组里；
/// 4. A 端删除分组 → B 端同步后分组消失、组内书回到"未分组"；
/// 5. B 端已有同名分组 → 同步后只保留一个（名称级去重，书籍合流）；
/// 6. 双端同时改名 → LWW 定序收敛到两端一致；
/// 7. 离线可用：离线改名本地立即生效，联网后补推。
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
    tempDirA = await Directory.systemTemp.createTemp('sync_group_a');
    tempDirB = await Directory.systemTemp.createTemp('sync_group_b');
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

  /// 在指定端导入一本书（可放进分组）。
  Future<void> importBook(
    InMemoryLocalLibrary library,
    String bookId, {
    String? groupId,
    String title = '双端书',
    List<int>? content,
  }) async {
    // 内容按 bookId 区分：同 hash 会触发全局去重（docs/05 §4.3），
    // 那样两本书会并成一本，测不到"分组合流"。
    final bytes = content ?? [bookId.codeUnitAt(bookId.length - 1), 2, 3];
    final (file, hash) = await writeTempContent(tempDirA, '$bookId.src', bytes);
    await library.importLocalBook(
      bookId: bookId,
      title: title,
      format: 'txt',
      contentHash: hash,
      sizeBytes: bytes.length,
      sourceFile: file,
    );
    if (groupId != null) {
      await library.setBookGroup(bookId, groupId);
    }
  }

  test('A 新建分组并归组书籍 → B 同步后出现同名分组且书在该分组里', () async {
    final groupId = groupIdOf(1);
    final bookId = bookIdOf(1);

    await libraryA.importLocalGroup(groupId: groupId, name: '小说');
    await importBook(libraryA, bookId, groupId: groupId);

    now = t0.add(const Duration(minutes: 1));
    final reportA = await engineA.fullSync();
    expect(reportA.success, isTrue, reason: '${reportA.results}');
    expect(reportA.groupDecisions[groupId], SyncDecision.localNewPush);

    // 云端：分组与书籍 meta 都带 groupId。
    final cloudGroup = await cloud.getGroup(groupId);
    expect(cloudGroup?.name, '小说');
    final cloudBook = await cloud.getMeta(bookId);
    expect(cloudBook?.groupId, groupId, reason: '书籍 meta 携带分组 id');

    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');
    expect(reportB.groupDecisions[groupId], SyncDecision.newFromCloud);

    // B 端：分组出现 + 书落在该分组。
    final groupOnB = await libraryB.group(groupId);
    expect(groupOnB?.name, '小说');
    final bookOnB = await libraryB.book(bookId);
    expect(bookOnB?.meta?.groupId, groupId);
  });

  test('A 重命名分组 → B 同步后分组名更新', () async {
    final groupId = groupIdOf(1);
    await libraryA.importLocalGroup(groupId: groupId, name: '小说');
    now = t0.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();

    await libraryA.renameLocalGroup(groupId, '长篇');
    now = now.add(const Duration(minutes: 1));
    final reportA = await engineA.fullSync();
    expect(reportA.success, isTrue, reason: '${reportA.results}');
    expect((await cloud.getGroup(groupId))?.name, '长篇');

    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');
    expect((await libraryB.group(groupId))?.name, '长篇');
  });

  test('A 删除分组 → B 同步后分组消失、组内书回到未分组', () async {
    final groupId = groupIdOf(1);
    final bookId = bookIdOf(1);
    await libraryA.importLocalGroup(groupId: groupId, name: '小说');
    await importBook(libraryA, bookId, groupId: groupId);
    now = t0.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();
    expect((await libraryB.book(bookId))?.meta?.groupId, groupId);

    // A 本地删除分组（软删：组内书回未分组）+ 推墓碑。
    await libraryA.deleteLocalGroup(groupId);
    now = now.add(const Duration(minutes: 1));
    final reportA = await engineA.fullSync();
    expect(reportA.success, isTrue, reason: '${reportA.results}');
    expect(reportA.groupDecisions[groupId], SyncDecision.deletePush);
    expect((await cloud.getGroup(groupId))?.isTombstone, isTrue);

    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');

    // B 端：分组消失，书仍在（不丢书），但回到未分组。
    expect(await libraryB.group(groupId), isNull);
    final bookOnB = await libraryB.book(bookId);
    expect(bookOnB, isNotNull, reason: '分组删除不丢书');
    expect(bookOnB?.meta?.groupId, isNull, reason: '组内书回到未分组');
  });

  test('B 端已有同名分组 → 同步后只保留一个分组，书籍合流', () async {
    final groupA = groupIdOf(1);
    final groupB = groupIdOf(2);
    final bookA = bookIdOf(1);
    final bookB = bookIdOf(2);

    // 两端各自建了同名分组「小说」（各拖一本书）。
    await libraryA.importLocalGroup(groupId: groupA, name: '小说');
    await importBook(libraryA, bookA, groupId: groupA);
    await libraryB.importLocalGroup(groupId: groupB, name: '小说');
    await importBook(libraryB, bookB, groupId: groupB);

    now = t0.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();

    // B 同步时：本地 B 分组与云端 A 分组同名 → 名称级去重合并。
    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');

    final groupsOnB = await libraryB.listGroups();
    final liveOnB = groupsOnB.where((g) => !g.deleted).toList();
    expect(liveOnB, hasLength(1), reason: '同名分组必须合并成一个');
    expect(liveOnB.single.name, '小说');

    // 两本书都在合并后的分组里。
    final canonical = liveOnB.single.groupId;
    expect((await libraryB.book(bookA))?.meta?.groupId, canonical);
    expect((await libraryB.book(bookB))?.meta?.groupId, canonical);
  });

  test('双端同时改名 → LWW 定序收敛到两端一致', () async {
    final groupId = groupIdOf(1);
    await libraryA.importLocalGroup(groupId: groupId, name: '小说');
    now = t0.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();

    // 两端离线各改一次名（B 端更晚 → B 胜）。
    await libraryA.renameLocalGroup(groupId, '长篇');
    now = now.add(const Duration(minutes: 1));
    await libraryB.renameLocalGroup(groupId, '经典');

    now = now.add(const Duration(minutes: 2));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');

    // B 端定序更晚 → 「经典」胜出；A 端再同步后收敛到同一名称。
    final winner = (await cloud.getGroup(groupId))!.name;
    expect(winner, '经典');
    now = now.add(const Duration(minutes: 1));
    await engineA.fullSync();
    expect((await libraryA.group(groupId))?.name, winner);
    expect((await libraryB.group(groupId))?.name, winner);
  });

  test('离线改名本地立即生效，联网后补推', () async {
    final groupId = groupIdOf(1);
    await libraryA.importLocalGroup(groupId: groupId, name: '小说');
    now = t0.add(const Duration(minutes: 1));
    await engineA.fullSync();

    // 离线改名（此时云端不可达）。
    await libraryA.renameLocalGroup(groupId, '离线改名');
    expect((await libraryA.group(groupId))?.name, '离线改名');
    expect((await cloud.getGroup(groupId))?.name, '小说', reason: '离线未上云');

    // 恢复联网 → 补推。
    now = now.add(const Duration(minutes: 5));
    final report = await engineA.fullSync();
    expect(report.success, isTrue, reason: '${report.results}');
    expect((await cloud.getGroup(groupId))?.name, '离线改名');
  });
}
