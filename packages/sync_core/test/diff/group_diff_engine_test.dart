/// 分组 Diff 决策矩阵单测（docs/04 §5.1 在分组维度的展开）。
library;

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

LocalGroupSnapshot snap(
  String groupId, {
  bool dirty = false,
  bool deleted = false,
  bool hasBaseRev = false,
  int baseRev = 0,
  String name = '小说',
}) => LocalGroupSnapshot(
  groupId: groupId,
  name: name,
  sortOrder: 0,
  createdAt: t0,
  exists: true,
  deleted: deleted,
  dirty: dirty,
  hasBaseRev: hasBaseRev,
  baseRev: baseRev,
);

RemoteGroupStub stub(String groupId, {int rev = 1, bool deleted = false}) =>
    RemoteGroupStub(groupId: groupId, rev: rev, name: '小说', deleted: deleted);

void main() {
  const differ = GroupDiffEngine();

  test('本地新分组（无 baseRev）+ 远端无 → 上架', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), dirty: true)],
      remote: const GroupListing(stubs: {}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.localNewPush);
    expect(plan.pushNeeded.map((e) => e.groupId), contains(groupIdOf(1)));
  });

  test('本地干净 + 远端 rev == baseRev → 同步', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), hasBaseRev: true, baseRev: 3)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 3)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.inSync);
    expect(plan.pullNeeded, isEmpty);
    expect(plan.pushNeeded, isEmpty);
  });

  test('本地脏 + 远端 rev == baseRev → 推送', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), dirty: true, hasBaseRev: true, baseRev: 3)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 3)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.pushLocal);
  });

  test('本地干净 + 远端 rev > baseRev → 拉取', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), hasBaseRev: true, baseRev: 2)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 5)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.pullRemote);
    expect(plan.pullNeeded.map((e) => e.groupId), contains(groupIdOf(1)));
  });

  test('本地脏 + 远端 rev > baseRev → 冲突合并', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), dirty: true, hasBaseRev: true, baseRev: 2)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 5)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.conflictMerge);
    expect(plan.pullNeeded.map((e) => e.groupId), contains(groupIdOf(1)));
    expect(plan.pushNeeded.map((e) => e.groupId), contains(groupIdOf(1)));
  });

  test('远端 rev 回退 → 保守走合并（rev 只增不变式被破坏）', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), hasBaseRev: true, baseRev: 7)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 2)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.conflictMerge);
  });

  test('云端新增分组 → 拉取', () {
    final plan = differ.diff(
      local: const [],
      remote: GroupListing(stubs: {groupIdOf(2): stub(groupIdOf(2))}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(2)], SyncDecision.newFromCloud);
    expect(plan.pullNeeded.map((e) => e.groupId), contains(groupIdOf(2)));
  });

  test('云端墓碑 + 本地无 → 无操作', () {
    final plan = differ.diff(
      local: const [],
      remote: GroupListing(
        stubs: {groupIdOf(2): stub(groupIdOf(2), deleted: true)},
      ),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(2)], SyncDecision.cloudTombstoneNoLocal);
  });

  test('本地已删除 + 云端仍是活分组 → 推墓碑', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), deleted: true, hasBaseRev: true, baseRev: 2)],
      remote: GroupListing(stubs: {groupIdOf(1): stub(groupIdOf(1), rev: 2)}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.deletePush);
    expect(plan.pushNeeded.map((e) => e.groupId), contains(groupIdOf(1)));
  });

  test('本地已删除 + 云端已无 → 无操作（幂等）', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), deleted: true, hasBaseRev: true, baseRev: 2)],
      remote: const GroupListing(stubs: {}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.cloudTombstoneNoLocal);
    expect(plan.pushNeeded, isEmpty);
  });

  test('曾有 baseRev 而云端分组消失 → 保留本地（云端缺失，不推）', () {
    final plan = differ.diff(
      local: [snap(groupIdOf(1), hasBaseRev: true, baseRev: 4)],
      remote: const GroupListing(stubs: {}),
      syncStates: const {},
    );
    expect(plan.decisions[groupIdOf(1)], SyncDecision.cloudMissing);
    expect(plan.pushNeeded, isEmpty);
  });
}
