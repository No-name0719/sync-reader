import 'dart:convert';

import '../internal/json_fields.dart';

/// 分组元数据 schema 版本（docs/05 §2.1）。
///
/// 分组是**独立文件类型**（云端 `groups/{groupId}.json`），与书籍 meta
/// `schemaVersion` 各自独立演进：初版为 1，演进规则同 docs/05 §6
/// （只增不删、读方容忍未知字段）。
const int kGroupSchemaVersion = 1;

/// 分组元数据，与云端 `groups/{groupId}.json` 一一对应（docs/05 §2.1）。
///
/// 分组（FR-107）与书籍 meta 同构：**每个分组自带 rev**，因此「改 A 组名」
/// 与「改 B 组名」互不冲突；改名 / 排序 / 删除都走与书籍一致的
/// `(rev, updatedAt, deviceId)` LWW + CAS 乐观锁（docs/04 §6.2）。
///
/// `fromJson` 执行严格校验，失败抛 [FormatException]——调用方把该分组记为
/// `Corruption` 并跳过，不得阻塞全库同步（docs/05 §6）。
class GroupMeta {
  const GroupMeta({
    required this.schemaVersion,
    required this.groupId,
    required this.rev,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.updatedAt,
    required this.name,
    required this.sortOrder,
    this.deleted = false,
    this.deletedAt,
  });

  final int schemaVersion;
  final String groupId; // ULID，= 文件名主干
  final int rev; // 写端单调递增，≥1
  final String deviceId; // 最后写入设备（决胜第三位）
  final String deviceName; // 展示用
  final DateTime createdAt;
  final DateTime updatedAt; // 决胜第二位（毫秒精度）
  final bool deleted; // tombstone 标记
  final DateTime? deletedAt; // GC 依据（90 天，docs/04 §7.3）
  final String name; // 分组名
  final int sortOrder; // 排序权重（升序）

  bool get isTombstone => deleted;

  /// 冲突比较键：先 rev，再 updatedAt，再 deviceId 字典序（docs/04 §6.2）。
  int compareTo(GroupMeta other) {
    if (rev != other.rev) return rev.compareTo(other.rev);
    final byTime = updatedAt.compareTo(other.updatedAt);
    if (byTime != 0) return byTime;
    return deviceId.compareTo(other.deviceId);
  }

  /// 生成本分组的 tombstone 形态（同一文件名、`deleted=true`）。
  GroupMeta toTombstone({
    required DateTime deletedAt,
    required String deviceId,
    required String deviceName,
  }) {
    return GroupMeta(
      schemaVersion: schemaVersion,
      groupId: groupId,
      rev: rev + 1,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: createdAt,
      updatedAt: deletedAt,
      deleted: true,
      deletedAt: deletedAt,
      name: name,
      sortOrder: sortOrder,
    );
  }

  /// 构造同内容、不同 rev 的副本（合并后抬 rev 用）。
  GroupMeta withRev(int rev) => GroupMeta(
    schemaVersion: schemaVersion,
    groupId: groupId,
    rev: rev,
    deviceId: deviceId,
    deviceName: deviceName,
    createdAt: createdAt,
    updatedAt: updatedAt,
    deleted: deleted,
    deletedAt: deletedAt,
    name: name,
    sortOrder: sortOrder,
  );

  factory GroupMeta.fromJson(Map<String, Object?> json) {
    final schemaVersion = requireInt(json, 'schemaVersion');
    if (schemaVersion < 1) {
      throw const FormatException('schemaVersion 必须 ≥ 1');
    }
    final deleted = json['deleted'] == true;
    return GroupMeta(
      schemaVersion: schemaVersion,
      groupId: requireString(json, 'groupId'),
      rev: requireRev(json),
      deviceId: requireString(json, 'deviceId'),
      deviceName: requireString(json, 'deviceName'),
      createdAt: requireTime(json, 'createdAt'),
      updatedAt: requireTime(json, 'updatedAt'),
      deleted: deleted,
      deletedAt: deleted ? optionalTime(json, 'deletedAt') : null,
      name: requireString(json, 'name'),
      sortOrder: requireInt(json, 'sortOrder'),
    );
  }

  factory GroupMeta.fromJsonString(String source) =>
      GroupMeta.fromJson((jsonDecode(source) as Map).cast<String, Object?>());

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'groupId': groupId,
    'rev': rev,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deleted': deleted,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'name': name,
    'sortOrder': sortOrder,
  };

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() =>
      'GroupMeta($groupId "$name" rev=$rev${deleted ? ' [tombstone]' : ''})';
}
