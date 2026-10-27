/// 配额闸门（docs/04 §8.3，FR-407，仅 WebDAV 模式语义）：
///
/// - 本地按自然月累计对坚果云的上/下行字节数（持久化于 sync_cursor 表）；
/// - 达到 80%（上行 800MB / 下行 2.4GB 量级）→ UI 常驻提醒 + 自动批量下载
///   暂停（元数据同步继续）；
/// - 达到 100% → 正文传输挂起至次月，手动可越权（二次确认由 UI 层做）；
/// - 字节计量经 TransferQueue.onBytes 埋点写入 DriftSyncStore（[record]）。
library;

import '../../data/sync/drift_sync_store.dart';

/// 配额上限与告警阈值常量（坚果云免费额度 上行 1GB / 下行 3GB，80% 告警）。
abstract final class QuotaLimits {
  /// 月度上行额度（1 GiB）。
  static const int upLimitBytes = 1024 * 1024 * 1024;

  /// 月度下行额度（3 GiB）。
  static const int downLimitBytes = 3 * 1024 * 1024 * 1024;

  /// 告警阈值比例（FR-407：默认上行 800MB / 下行 2.4GB，即额度的 80%）。
  static const double warnRatio = 0.8;

  /// 上行告警阈值字节（FR-407：默认上行 800MB 量级 = 额度的 80%）。
  /// 取上取整：恰好达到该字节数时比例已 ≥ 80%。
  static int get upWarnBytes => (upLimitBytes * warnRatio).ceil();

  /// 下行告警阈值字节（2.4GB 量级）。
  static int get downWarnBytes => (downLimitBytes * warnRatio).ceil();
}

/// 配额快照（设置页面板 / 书库横幅告警用）。
class QuotaSnapshot {
  const QuotaSnapshot({this.upBytes = 0, this.downBytes = 0, this.month});

  final int upBytes;
  final int downBytes;

  /// 快照所属自然月（如 `2026-10`）。
  final String? month;

  /// 上行用量比例（0.0–∞，UI 端 clamp）。
  double get upRatio =>
      QuotaLimits.upLimitBytes <= 0 ? 0 : upBytes / QuotaLimits.upLimitBytes;

  /// 下行用量比例。
  double get downRatio => QuotaLimits.downLimitBytes <= 0
      ? 0
      : downBytes / QuotaLimits.downLimitBytes;

  /// 任一方向已达 80% 告警线。
  bool get warn =>
      upRatio >= QuotaLimits.warnRatio || downRatio >= QuotaLimits.warnRatio;

  /// 下行已达 100%（正文传输挂起）。
  bool get downExceeded => downBytes >= QuotaLimits.downLimitBytes;
}

/// 配额闸门。内存缓存快照 + [DriftSyncStore] 持久计数。
///
/// TransferQueue 的 quotaGate 钩子是同步函数，因此 [allowDownload] 走缓存
/// （[refresh] 装载、[record] 写入即更新）；跨月清零在 [refresh]/[record]
/// 读改写时生效。
final class SyncQuotaGate {
  /// 构造；[backendKey] 与 DriftSyncStore 一致（FR-405 同期仅一个后端）。
  SyncQuotaGate({required this._store, this.backendKey = 'webdav'});

  final DriftSyncStore _store;
  final String backendKey;

  QuotaSnapshot _snapshot = const QuotaSnapshot();

  /// 当前快照（缓存）。
  QuotaSnapshot get snapshot => _snapshot;

  /// 从持久层装载（跨月自动清零在 addQuotaUsage 落库时保证，这里再兜底）。
  Future<QuotaSnapshot> refresh({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final raw = await _store.cursorSnapshot(backendKey);
    final month = DriftSyncStore.quotaMonthOf(at);
    final sameMonth = raw.quotaMonth == month;
    _snapshot = QuotaSnapshot(
      upBytes: sameMonth ? raw.quotaUpBytes : 0,
      downBytes: sameMonth ? raw.quotaDownBytes : 0,
      month: month,
    );
    return _snapshot;
  }

  /// 记录一笔流量（TransferQueue.onBytes 埋点调用），写持久层并更新缓存。
  Future<void> record(int upBytes, int downBytes, {DateTime? now}) async {
    final updated = await _store.addQuotaUsage(
      upBytes: upBytes,
      downBytes: downBytes,
      now: now,
    );
    _snapshot = QuotaSnapshot(
      upBytes: updated.quotaUpBytes,
      downBytes: updated.quotaDownBytes,
      month: updated.quotaMonth,
    );
  }

  /// 清空内存缓存（清除凭据/切换后端后由门面调用；下次 refresh 重载）。
  void resetCache() {
    _snapshot = const QuotaSnapshot();
  }

  /// 是否允许本次正文下载（纯决策，可测）。
  ///
  /// - 越权放行（手动确认）→ 恒 true；
  /// - 已用 + 估算 > 月度下行额度 → false（TransferQueue 抛 QuotaExceeded
  ///   挂起该任务，次月自动恢复）；
  /// - 元数据同步不受限（由引擎保证，闸门只挂正文下载）。
  static bool decide({
    required int downBytes,
    required int estBytes,
    required bool override,
  }) {
    if (override) return true;
    // 达到 100%：正文传输全部挂起至次月（docs/04 §8.3）。
    if (downBytes >= QuotaLimits.downLimitBytes) return false;
    return downBytes + estBytes <= QuotaLimits.downLimitBytes;
  }

  /// 同步判定（供 TransferQueue.quotaGate 钩子）。
  bool allowDownload(int estBytes, {bool override = false}) => decide(
    downBytes: _snapshot.downBytes,
    estBytes: estBytes,
    override: override,
  );

  /// 80% 告警文案（null = 未达告警线）。
  static String? warnText(QuotaSnapshot snapshot) {
    if (!snapshot.warn) return null;
    if (snapshot.downExceeded) {
      return '本月同步流量已达上限，正文下载已挂起（可在下方手动放行）';
    }
    return '本月同步流量已超过 80%，自动下载已放缓';
  }
}
