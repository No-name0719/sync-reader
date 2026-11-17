import '../backend/backend_adapter.dart';
import '../diff/diff_engine.dart';
import '../store/local_library.dart';
import '../store/sync_store.dart';

/// 单个分组的 Diff 结论（与书籍同构，docs/04 §5.1）。
class GroupSyncPlanEntry {
  const GroupSyncPlanEntry({
    required this.groupId,
    required this.decision,
    this.remote,
    this.local,
    this.remoteIsTombstone = false,
  });

  final String groupId;
  final SyncDecision decision;

  /// 清单中的远端摘要（远端存在时）。
  final RemoteGroupStub? remote;

  /// 本地快照（本地存在时）。
  final LocalGroupSnapshot? local;

  /// 远端当前是墓碑（分组已删除）。
  final bool remoteIsTombstone;

  @override
  String toString() => 'GroupSyncPlanEntry($groupId, $decision)';
}

/// 一次分组 Diff 的完整计划（docs/04 §5.1 矩阵在分组维度的展开）。
class GroupSyncPlan {
  GroupSyncPlan({required List<GroupSyncPlanEntry> entries})
    : entries = List.unmodifiable(entries);

  final List<GroupSyncPlanEntry> entries;

  /// groupId → 决策。
  Map<String, SyncDecision> get decisions => {
    for (final e in entries) e.groupId: e.decision,
  };

  /// 需要拉取远端分组 meta 的条目（阶段 3 PullMetas 输入）。
  List<GroupSyncPlanEntry> get pullNeeded => entries
      .where(
        (e) =>
            e.decision == SyncDecision.pullRemote ||
            e.decision == SyncDecision.conflictMerge ||
            e.decision == SyncDecision.newFromCloud,
      )
      .toList();

  /// 需要推送分组 meta 的条目（阶段 4 PushMetas 输入）。
  List<GroupSyncPlanEntry> get pushNeeded => entries
      .where(
        (e) =>
            e.decision == SyncDecision.pushLocal ||
            e.decision == SyncDecision.conflictMerge ||
            e.decision == SyncDecision.localNewPush ||
            e.decision == SyncDecision.deletePush,
      )
      .toList();
}

/// 分组差异比对引擎（docs/04 §5.1 决策矩阵在分组维度的等价物，纯函数）。
///
/// 规则与书籍一致，只是分组没有正文与阅读进度：
///
/// | 本地 | 远端 | 判定 | 动作 |
/// | --- | --- | --- | --- |
/// | 有，未删 | 有，rev == baseRev | 同步 | 无 |
/// | 有，未删 | 有，rev > baseRev | 落后 | 拉取分组 meta → 应用（改名/排序） |
/// | 有，未删 | 有，rev > baseRev 且本地 dirty | 冲突 | §6 合并后推送 |
/// | 有，未删 | 无 | 本地新分组 | 推送分组 meta（第 7a 行） |
/// | 有，已删 | 有（未删） | 本地删除 | 推墓碑（docs/04 §7.1 分组同款语义） |
/// | 有，已删 | 无 | 已删除且云端无 | 无操作 |
/// | 无 | 有（未删） | 云端新增分组 | 拉取分组 meta → 本地建组 |
/// | 无 | 有（墓碑） | 云端已删 | 无操作 |
class GroupDiffEngine {
  const GroupDiffEngine();

  /// 对本地分组快照 × 远端分组清单 × 分组同步状态做全量比对。
  GroupSyncPlan diff({
    required List<LocalGroupSnapshot> local,
    required GroupListing remote,
    required Map<String, GroupSyncStateSnapshot> syncStates,
  }) {
    final entries = <GroupSyncPlanEntry>[];
    final ids = <String>{
      for (final s in local) s.groupId,
      ...remote.stubs.keys,
    };
    for (final id in ids) {
      final snap = _find(local, id);
      final stub = remote.stubs[id];
      final state = syncStates[id];
      entries.add(_decide(id, snap, stub, state));
    }
    return GroupSyncPlan(entries: entries);
  }

  GroupSyncPlanEntry _decide(
    String groupId,
    LocalGroupSnapshot? snap,
    RemoteGroupStub? stub,
    GroupSyncStateSnapshot? state,
  ) {
    // 本地已删除（待推墓碑）。
    if (snap != null && snap.deleted) {
      if (stub == null || stub.deleted) {
        // 云端已无该分组（或已是墓碑）→ 幂等，无需动作。
        return GroupSyncPlanEntry(
          groupId: groupId,
          decision: SyncDecision.cloudTombstoneNoLocal,
          local: snap,
          remote: stub,
          remoteIsTombstone: stub?.deleted ?? false,
        );
      }
      // 云端仍是活分组 → 推墓碑让它在其它设备消失。
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.deletePush,
        local: snap,
        remote: stub,
      );
    }

    if (snap != null && stub != null) {
      return _decideBothPresent(groupId, snap, stub, state);
    }

    if (snap != null && stub == null) {
      // 第 7a 行：从未推送过 → 视为本地新分组上架。
      final hasBase = state != null || snap.hasBaseRev;
      if (!hasBase) {
        return GroupSyncPlanEntry(
          groupId: groupId,
          decision: SyncDecision.localNewPush,
          local: snap,
        );
      }
      // 第 7b 行：曾有 baseRev 而远端分组消失 → 保留本地，标记"云端缺失"。
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.cloudMissing,
        local: snap,
      );
    }

    // 本地无、远端有。
    if (stub!.deleted) {
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.cloudTombstoneNoLocal,
        remote: stub,
        remoteIsTombstone: true,
      );
    }
    return GroupSyncPlanEntry(
      groupId: groupId,
      decision: SyncDecision.newFromCloud,
      remote: stub,
    );
  }

  GroupSyncPlanEntry _decideBothPresent(
    String groupId,
    LocalGroupSnapshot snap,
    RemoteGroupStub stub,
    GroupSyncStateSnapshot? state,
  ) {
    if (stub.deleted) {
      // 远端是墓碑（分组已删）→ 本地还在 → 拉取并按删除应用。
      if (snap.hasBaseRev && stub.rev > snap.baseRev) {
        return GroupSyncPlanEntry(
          groupId: groupId,
          decision: SyncDecision.pullRemote,
          remote: stub,
          local: snap,
          remoteIsTombstone: true,
        );
      }
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.inSync,
        remote: stub,
        local: snap,
        remoteIsTombstone: true,
      );
    }

    final hasBase = state != null || snap.hasBaseRev;
    final baseRev = state?.baseRev ?? snap.baseRev;

    // 无 baseRev 而云端已有同名/同 id 分组：无法判定祖先，保守走合并。
    if (!hasBase) {
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }

    // rev 回退（网盘回档等异常）→ 保守走合并。
    if (stub.rev < baseRev) {
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }

    if (stub.rev == baseRev) {
      if (snap.dirty) {
        return GroupSyncPlanEntry(
          groupId: groupId,
          decision: SyncDecision.pushLocal,
          remote: stub,
          local: snap,
        );
      }
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.inSync,
        remote: stub,
        local: snap,
      );
    }

    // 远端 rev 更高：本地 dirty → 冲突合并；否则拉取远端。
    if (snap.dirty) {
      return GroupSyncPlanEntry(
        groupId: groupId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }
    return GroupSyncPlanEntry(
      groupId: groupId,
      decision: SyncDecision.pullRemote,
      remote: stub,
      local: snap,
    );
  }

  LocalGroupSnapshot? _find(List<LocalGroupSnapshot> list, String groupId) {
    for (final s in list) {
      if (s.groupId == groupId) return s;
    }
    return null;
  }
}
