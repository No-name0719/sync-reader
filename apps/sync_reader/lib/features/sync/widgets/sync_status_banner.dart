/// 书库顶部同步状态横幅（FR-406 全局态可视化；点击进入同步设置页）。
///
/// 只消费 [syncMemoryStatusProvider] 等状态 provider，不触碰引擎。
/// 80% 常驻提醒（docs/04 §8.3）：内存侧实时告警优先，否则从持久化配额
/// 快照推导——冷启动尚未同步也能把警示带到书库横幅。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/format_utils.dart';
import '../quota_gate.dart';
import '../sync_facade.dart';
import '../sync_status.dart';

/// 全局同步状态横幅。
class SyncStatusBanner extends ConsumerWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final memory = ref.watch(syncMemoryStatusProvider);
    final lastPersisted = ref.watch(lastFullSyncAtProvider).value;
    final theme = Theme.of(context);

    // 配额告警链路：内存侧（同步轮次实时上报）→ 持久化快照推导兜底。
    final snap = ref.watch(quotaSnapshotProvider).value;
    final quotaWarn =
        memory.quotaWarnText ??
        (snap == null ? null : SyncQuotaGate.warnText(snap));
    // 空闲/正常态下直接以警示文案替代默认文本（提醒更明确）；
    // 同步中/失败/未配置态保留原语义，仅在尾部显示警示图标。
    final quotaWarnAsText =
        quotaWarn != null &&
        (memory.id == SyncStateId.idle || memory.id == SyncStateId.ok);

    var (icon, color, text) = switch (memory.id) {
      SyncStateId.unconfigured => (
        Icons.cloud_off_outlined,
        theme.colorScheme.outline,
        '云端同步未配置，点此设置',
      ),
      SyncStateId.idle => (
        Icons.cloud_outlined,
        theme.colorScheme.outline,
        '同步空闲',
      ),
      SyncStateId.syncing => (Icons.sync, theme.colorScheme.primary, '正在同步…'),
      SyncStateId.ok => (
        Icons.cloud_done_outlined,
        Colors.green.shade600,
        '上次同步：${_formatLast(memory.lastSyncedAt, lastPersisted)}',
      ),
      SyncStateId.failed => (
        Icons.cloud_off,
        theme.colorScheme.error,
        '同步失败：${memory.failureText ?? '未知原因'}',
      ),
    };
    if (quotaWarnAsText) {
      icon = Icons.warning_amber_rounded;
      color = theme.colorScheme.error;
      text = quotaWarn;
    }

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: InkWell(
        onTap: () => context.push('/sync/settings'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ),
              if (quotaWarn != null && !quotaWarnAsText) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: theme.colorScheme.error,
                ),
              ],
              const Icon(Icons.chevron_right, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  /// 会话内时间与持久化时间取较新者。
  String _formatLast(DateTime? session, DateTime? persisted) {
    DateTime? at = session;
    if (persisted != null && (at == null || persisted.isAfter(at))) {
      at = persisted;
    }
    return at == null ? '-' : formatEpochMs(at.millisecondsSinceEpoch);
  }
}
