import '../model/book_meta.dart';
import '../model/group_meta.dart';

/// 冲突合并器（docs/04 §6）：胜者框架 + 累积型字段特例。
///
/// 定序规则（§6.2）：`(rev, updatedAt, deviceId)` 三元组大者胜，
/// 已由 [BookMeta.compareTo] 实现（rev → updatedAt → deviceId 字典序）。
class ConflictResolver {
  const ConflictResolver();

  /// 合并两份并发修改的 meta。
  ///
  /// - 胜者 = `local.compareTo(remote)` 大者；框架字段（书信息/进度/locator）
  ///   全取胜者（§6.3，v1 接受并发书名修正丢失，docs/07-Q7）；
  /// - `rev = max(local.rev, remote.rev) + 1`；`updatedAt = now`；
  ///   `deviceId/deviceName` = 本机（合并结果由本机作为新写端推送）；
  /// - `totalSeconds = local + remote − max(ancestor 值, 0)`：以 baseRev 时点的
  ///   公共祖先扣除双计部分；ancestor 缺失（重装等）退化为直接求和（§6.3 实现注）；
  ///   结果 clamp ≥ 0；
  /// - `lastReadAt = max(local, remote)`；
  /// - tombstone 与正常 meta 走同一定序（§7.2）：胜者是 tombstone 则结果为
  ///   tombstone；正常 meta 胜出即"复活"。
  BookMeta merge({
    required BookMeta local,
    required BookMeta remote,
    BookMeta? ancestor,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  }) {
    final winner = local.compareTo(remote) >= 0 ? local : remote;
    final mergedRev = _maxInt(local.rev, remote.rev) + 1;
    final ancestorSeconds = ancestor?.reading.totalSeconds ?? 0;
    final totalSeconds = _maxInt(
      local.reading.totalSeconds +
          remote.reading.totalSeconds -
          _maxInt(ancestorSeconds, 0),
      0,
    );
    final lastReadAt = _maxTime(
      local.reading.lastReadAt,
      remote.reading.lastReadAt,
    );

    return BookMeta(
      schemaVersion: winner.schemaVersion,
      bookId: local.bookId,
      rev: mergedRev,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: winner.createdAt,
      updatedAt: now,
      // 胜者是 tombstone → 结果为 tombstone；胜者是正常 meta → 复活（§7.2）。
      deleted: winner.deleted,
      deletedAt: winner.deletedAt,
      dedupOf: winner.dedupOf,
      book: winner.book,
      progress: winner.progress,
      reading: ReadingStats(totalSeconds: totalSeconds, lastReadAt: lastReadAt),
      annotations: winner.annotations,
      extra: winner.extra,
    );
  }

  static int _maxInt(int a, int b) => a >= b ? a : b;

  static DateTime _maxTime(DateTime a, DateTime b) => a.isAfter(b) ? a : b;

  /// 合并两份并发修改的**分组** meta（docs/04 §6.3，分组同款胜者框架）。
  ///
  /// - 胜者 = `local.compareTo(remote)` 大者（rev -> updatedAt -> deviceId）；
  /// - 框架字段（名称 `name` / 排序权重 `sortOrder`）全取胜者；
  /// - `rev = max(local.rev, remote.rev) + 1`；`updatedAt = now`；
  ///   `deviceId/deviceName` = 本机（合并结果由本机作为新写端推送）；
  /// - 分组墓碑与正常 meta 走同一定序（docs/04 §7.2）：胜者是墓碑则结果为
  ///   墓碑（分组在其它设备消失，组内书籍回到未分组）。
  GroupMeta mergeGroup({
    required GroupMeta local,
    required GroupMeta remote,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  }) {
    final winner = local.compareTo(remote) >= 0 ? local : remote;
    return GroupMeta(
      schemaVersion: winner.schemaVersion,
      groupId: local.groupId,
      rev: _maxInt(local.rev, remote.rev) + 1,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: winner.createdAt,
      updatedAt: now,
      deleted: winner.deleted,
      deletedAt: winner.deletedAt,
      name: winner.name,
      sortOrder: winner.sortOrder,
    );
  }
}
