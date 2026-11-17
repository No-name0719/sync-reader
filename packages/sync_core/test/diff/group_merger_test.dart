/// 同名分组去重规划器单测（docs/05 §2.1 名称级去重规则）。
library;

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// 构造本地分组快照。
LocalGroupSnapshot localGroup(
  String groupId, {
  String name = '小说',
  int sortOrder = 0,
  bool deleted = false,
}) => LocalGroupSnapshot(
  groupId: groupId,
  name: name,
  sortOrder: sortOrder,
  createdAt: t0,
  exists: true,
  deleted: deleted,
  dirty: false,
  hasBaseRev: false,
  baseRev: 0,
);

/// 构造远端分组摘要。
RemoteGroupStub remoteGroup(
  String groupId, {
  String name = '小说',
  int rev = 1,
  int sortOrder = 0,
  bool deleted = false,
}) => RemoteGroupStub(
  groupId: groupId,
  rev: rev,
  name: name,
  sortOrder: sortOrder,
  deleted: deleted,
);

void main() {
  const merger = GroupMerger();

  test('无同名冲突 → 空计划', () {
    final plan = merger.plan(
      local: [localGroup(groupIdOf(1), name: '小说')],
      remote: {groupIdOf(2): remoteGroup(groupIdOf(2), name: '长篇')},
    );
    expect(plan.isEmpty, isTrue);
  });

  test('本地与云端同名不同 id → 合并到 id 较小者（规则对两端对称）', () {
    final plan = merger.plan(
      local: [localGroup(groupIdOf(1), name: '小说')],
      remote: {groupIdOf(2): remoteGroup(groupIdOf(2), name: '小说')},
    );
    expect(plan.absorptions, hasLength(1));
    final a = plan.absorptions.single;
    expect(a.toGroupId, groupIdOf(1), reason: '规范 id = 簇内最小 id');
    expect(a.fromGroupId, groupIdOf(2));
    expect(a.fromIsLocal, isFalse);
    expect(a.fromIsRemote, isTrue);
    expect(a.toIsRemote, isFalse);
  });

  test('云端有两条同名 → 取字典序最小者为规范，其余被吸收', () {
    final plan = merger.plan(
      local: const [],
      remote: {
        groupIdOf(5): remoteGroup(groupIdOf(5), name: '小说'),
        groupIdOf(3): remoteGroup(groupIdOf(3), name: '小说'),
      },
    );
    expect(plan.absorptions, hasLength(1));
    final a = plan.absorptions.single;
    expect(a.toGroupId, groupIdOf(3), reason: 'ULID 字典序最小者为规范');
    expect(a.fromGroupId, groupIdOf(5));
    expect(a.fromIsRemote, isTrue);
  });

  test('两端各自建同名分组且都上过云 → 两端结论一致（对称，不乒乓）', () {
    // A 端视角：本地 A1 + 云端 B1（两条都在云端的那一轮）。
    final planA = merger.plan(
      local: [localGroup(groupIdOf(1), name: '小说')],
      remote: {
        groupIdOf(1): remoteGroup(groupIdOf(1), name: '小说'),
        groupIdOf(2): remoteGroup(groupIdOf(2), name: '小说'),
      },
    );
    // B 端视角：本地 B1 + 云端 A1 —— id 集合相同 → 规范 id 必须相同。
    final planB = merger.plan(
      local: [localGroup(groupIdOf(2), name: '小说')],
      remote: {
        groupIdOf(1): remoteGroup(groupIdOf(1), name: '小说'),
        groupIdOf(2): remoteGroup(groupIdOf(2), name: '小说'),
      },
    );
    expect(planA.absorptions.single.toGroupId, groupIdOf(1));
    expect(planB.absorptions.single.toGroupId, groupIdOf(1));
    expect(
      planA.absorptions.single.toGroupId,
      planB.absorptions.single.toGroupId,
      reason: '两端必须收敛到同一个规范分组（否则各留各的）',
    );
  });

  test('本地已删除（待推墓碑）与远端墓碑都不参与合并', () {
    final plan = merger.plan(
      local: [
        localGroup(groupIdOf(1), name: '小说', deleted: true),
        localGroup(groupIdOf(3), name: '小说'),
      ],
      remote: {
        groupIdOf(2): remoteGroup(groupIdOf(2), name: '小说', deleted: true),
      },
    );
    // 仅 1 条（本地 groupIdOf(3)）与墓碑不构成同名冲突。
    expect(plan.isEmpty, isTrue);
  });

  test('改名冲突（同一 id 本地与远端名字不同）→ 跳过合并', () {
    final plan = merger.plan(
      local: [localGroup(groupIdOf(1), name: '长篇')],
      remote: {groupIdOf(1): remoteGroup(groupIdOf(1), name: '小说')},
    );
    expect(plan.isEmpty, isTrue, reason: '同名聚类各只有一个 id，无冲突');
  });

  test('空名分组不参与合并', () {
    final plan = merger.plan(
      local: [localGroup(groupIdOf(1), name: '')],
      remote: {groupIdOf(2): remoteGroup(groupIdOf(2), name: '')},
    );
    expect(plan.isEmpty, isTrue);
  });

  test('规范分组的名称/排序取自其自身来源（本地行或云端摘要）', () {
    // 规范 id = 本地那条（min）→ 用本地行的名称与排序。
    final plan = merger.plan(
      local: [localGroup(groupIdOf(1), name: '小说', sortOrder: 3)],
      remote: {
        groupIdOf(2): remoteGroup(groupIdOf(2), name: '小说', sortOrder: 9),
      },
    );
    final a = plan.absorptions.single;
    expect(a.toGroupId, groupIdOf(1));
    expect(a.toName, '小说');
    expect(a.toSortOrder, 3);
  });
}
