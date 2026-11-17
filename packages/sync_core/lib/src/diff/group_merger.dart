import '../backend/backend_adapter.dart';
import '../store/local_library.dart';

/// 同名分组的吸收步骤：把 [fromGroupId] 并入 [toGroupId]（docs/05 §2.1）。
///
/// 两台设备各自建了同名分组（「小说」）时，云端会出现两条同名记录。
/// 合并把本地 `from` 分组的书籍外键迁到 `to`，删除本地 `from` 行；
/// 若 `from` 只存在于云端（本地没有），则在规范分组确实存在于云端时
/// 删除这条冗余云端条目（避免每次同步都重复去重）。
class GroupAbsorption {
  const GroupAbsorption({
    required this.fromGroupId,
    required this.toGroupId,
    required this.toName,
    required this.toSortOrder,
    required this.fromIsLocal,
    required this.fromIsRemote,
    required this.toIsRemote,
  });

  /// 被吸收的分组 id。
  final String fromGroupId;

  /// 规范分组 id（保留方）。
  final String toGroupId;

  /// 规范分组的名称（本地建行时用；远端拉取阶段会被权威值覆盖）。
  final String toName;

  /// 规范分组的排序权重。
  final int toSortOrder;

  /// 被吸收者是否存在于本地。
  final bool fromIsLocal;

  /// 被吸收者是否存在于云端。
  final bool fromIsRemote;

  /// 规范分组是否存在于云端（决定能否清理冗余云端条目）。
  final bool toIsRemote;

  @override
  String toString() => 'GroupAbsorption($fromGroupId -> $toGroupId)';
}

/// 同名分组合并计划（docs/05 §2.1 名称级去重规则）。
class GroupMergePlan {
  GroupMergePlan({required List<GroupAbsorption> absorptions})
    : absorptions = List.unmodifiable(absorptions);

  /// 无同名冲突时的空计划。
  static final GroupMergePlan empty = GroupMergePlan(absorptions: const []);

  final List<GroupAbsorption> absorptions;

  bool get isEmpty => absorptions.isEmpty;

  /// 规范分组 id -> 被吸收的分组 id 列表。
  Map<String, List<String>> get byCanonical {
    final out = <String, List<String>>{};
    for (final a in absorptions) {
      (out[a.toGroupId] ??= <String>[]).add(a.fromGroupId);
    }
    return out;
  }
}

/// 同名分组去重规划器（纯函数，docs/05 §2.1）。
///
/// 规则：
/// 1. 名称为空、已本地删除（待推墓碑）、已是远端墓碑的分组**不参与**合并；
/// 2. 按分组名聚类（本地活分组 + 云端活分组）；
/// 3. 同一 groupId 若出现在多个名称聚类中（本地改名未同步 vs 远端改名），
///    视为改名冲突，**跳过合并**（由 id 级 LWW 定序解决）；
/// 4. 聚类内的规范 id = **全部 id 中字典序最小者**（ULID 时间有序 ->
///    最早创建者优先）；该规则对两端对称，避免"各并入云端那条"的乒乓；
/// 5. 其余 id 被吸收（本地行删除 + 书籍外键迁移；云端冗余条目清理）。
class GroupMerger {
  const GroupMerger();

  /// 计算同名分组合并计划。
  GroupMergePlan plan({
    required List<LocalGroupSnapshot> local,
    required Map<String, RemoteGroupStub> remote,
  }) {
    // 名称聚类：名称 -> 候选 id 集合。
    final clusters = <String, Set<String>>{};
    // id -> 出现过的**名称聚类集合**（>1 个名称 = 改名冲突，跳过合并）。
    final namesById = <String, Set<String>>{};
    final localById = <String, LocalGroupSnapshot>{};
    final remoteById = <String, RemoteGroupStub>{};

    void addToCluster(String name, String id) {
      clusters.putIfAbsent(name, () => <String>{}).add(id);
      (namesById[id] ??= <String>{}).add(name);
    }

    for (final snap in local) {
      if (snap.deleted) continue; // 本地已删除：走墓碑路径，不参与合并。
      final name = snap.name.trim();
      if (name.isEmpty) continue;
      addToCluster(name, snap.groupId);
      localById[snap.groupId] = snap;
    }
    for (final stub in remote.values) {
      if (stub.deleted) continue; // 远端墓碑：即将消失，不参与合并。
      final name = stub.name.trim();
      if (name.isEmpty) continue;
      addToCluster(name, stub.groupId);
      remoteById[stub.groupId] = stub;
    }

    final absorptions = <GroupAbsorption>[];
    for (final entry in clusters.entries) {
      final name = entry.key;
      // 改名冲突的 id 排除在外（同一 id 出现在多个名称聚类）。
      final ids = entry.value
          .where((id) => (namesById[id] ?? const <String>{}).length == 1)
          .toList();
      if (ids.length < 2) continue; // 无同名冲突。

      // 规范 id = 簇内**全体 id 中字典序最小者**（ULID 时间有序 -> 最早创建者）。
      // 该规则对两端对称：同样的 id 集合在 A/B 端得到同一个规范 id，
      // 避免"各把本地那条并入云端那条"造成的乒乓（两端各留各的）。
      final sorted = ids.toList()..sort();
      final canonical = sorted.first;

      final canonicalRemote = remoteById[canonical];
      final canonicalLocal = localById[canonical];
      final toName = canonicalRemote?.name ?? canonicalLocal?.name ?? name;
      final toSortOrder =
          canonicalRemote?.sortOrder ?? canonicalLocal?.sortOrder ?? 0;

      for (final id in ids) {
        if (id == canonical) continue;
        absorptions.add(
          GroupAbsorption(
            fromGroupId: id,
            toGroupId: canonical,
            toName: toName,
            toSortOrder: toSortOrder,
            fromIsLocal: localById.containsKey(id),
            fromIsRemote: remoteById.containsKey(id),
            toIsRemote: canonicalRemote != null,
          ),
        );
      }
    }
    return GroupMergePlan(absorptions: absorptions);
  }
}
