/// 同步设置页（FR-405/406/409/505）：
///
/// - 后端卡片：未配置 → 引导入口；已配置 → 坚果云 WebDAV + 账号 + 同步根；
/// - "立即同步"按钮：进行中指示 + 上次同步时间/失败原因（FR-406/409）；
/// - 自动同步开关 / 仅 Wi-Fi 正文开关（docs/04 §3 配置项）；
/// - 配额面板：月度上行/下行进度条 + 80%/100% 常驻警示条与越权放行
///   （FR-407/docs/04 §8.3）；
/// - 同步维护：云端孤儿清理（docs/04 §7.1 规则 4）；连接测试（见向导）；
///   清除凭据（危险区）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/format_utils.dart';
import '../quota_gate.dart';
import '../sync_facade.dart';
import '../sync_preferences.dart';
import '../sync_status.dart';
import 'cloud_orphan_cleanup_page.dart';

/// 同步设置页（`/sync/settings`）。
class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(syncConfigProvider);
    final prefs = ref.watch(syncPreferencesProvider);
    final memory = ref.watch(syncMemoryStatusProvider);
    final quotaAsync = ref.watch(quotaSnapshotProvider);
    final lastFullSyncAsync = ref.watch(lastFullSyncAtProvider);

    // 每轮同步结束/开关切换后刷新配置摘要、配额与持久化时间。
    ref.listen(syncMemoryStatusProvider, (_, _) {
      ref.invalidate(quotaSnapshotProvider);
      ref.invalidate(lastFullSyncAtProvider);
    });

    final lastSyncedAt = () {
      final session = memory.lastSyncedAt;
      final persisted = lastFullSyncAsync.value;
      if (session != null && persisted != null) {
        return session.isAfter(persisted) ? session : persisted;
      }
      return session ?? persisted;
    }();

    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      // 居中限宽（与引导页一致；窄窗 480px 不横向溢出，宽窗不无限拉伸）。
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            children: [
              // ── 后端卡片（FR-405）──
              configAsync.when(
                loading: () => const ListTile(
                  leading: Icon(Icons.cloud_outlined),
                  title: Text('正在读取后端配置…'),
                ),
                error: (error, _) => const ListTile(
                  leading: Icon(Icons.cloud_off),
                  title: Text('后端未配置'),
                  subtitle: Text('配置读取失败，可重新配置'),
                ),
                data: (config) => config == null
                    ? Card(
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: ListTile(
                          leading: const Icon(Icons.cloud_off),
                          title: const Text('后端未配置'),
                          subtitle: const Text('坚果云 WebDAV（引导式配置）'),
                          trailing: FilledButton(
                            onPressed: () => context.push('/sync/guide'),
                            child: const Text('去配置'),
                          ),
                        ),
                      )
                    : Card(
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: ListTile(
                          leading: const Icon(Icons.cloud_done_outlined),
                          title: const Text('坚果云 WebDAV'),
                          // Expanded 内自动换行：长账号/根目录不横向溢出。
                          subtitle: Text(
                            '${config.account}\n同步根：${config.rootPath}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            softWrap: true,
                          ),
                          isThreeLine: true,
                          trailing: TextButton(
                            onPressed: () => context.push('/sync/guide'),
                            child: const Text('重新配置'),
                          ),
                        ),
                      ),
              ),

              // ── 立即同步（FR-409）+ 状态行（FR-406）──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(switch (memory.id) {
                            SyncStateId.unconfigured => '云端同步未配置',
                            SyncStateId.idle => '同步空闲',
                            SyncStateId.syncing => '正在同步…',
                            SyncStateId.ok =>
                              '上次同步：'
                                  '${lastSyncedAt == null ? '-' : formatEpochMs(lastSyncedAt.millisecondsSinceEpoch)}',
                            SyncStateId.failed => '上次同步失败',
                          }, style: Theme.of(context).textTheme.bodyMedium),
                          if (memory.failureText != null)
                            Text(
                              '失败原因：${memory.failureText}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: memory.id == SyncStateId.syncing
                          ? null
                          : () => ref
                                .read(syncFacadeProvider)
                                .fullSync(source: SyncTriggerSource.manual),
                      icon: memory.id == SyncStateId.syncing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: const Text('立即同步'),
                    ),
                  ],
                ),
              ),

              const Divider(height: 32),

              // ── 自动同步开关（docs/04 §3）──
              SwitchListTile(
                title: const Text('自动同步'),
                subtitle: const Text('关闭后仅手动"立即同步"生效'),
                value: prefs.autoSyncEnabled,
                onChanged: (value) => ref
                    .read(syncPreferencesProvider.notifier)
                    .setAutoSyncEnabled(value),
              ),

              // ── 仅 Wi-Fi 正文开关 ──
              SwitchListTile(
                title: const Text('仅 Wi-Fi 同步正文'),
                subtitle: const Text('元数据不受限；正文下载避开移动网络'),
                value: prefs.wifiOnlyContent,
                onChanged: (value) => ref
                    .read(syncPreferencesProvider.notifier)
                    .setWifiOnlyContent(value),
              ),

              const Divider(height: 32),

              // ── 配额面板（FR-407；内存侧告警优先于快照推导）──
              _QuotaPanel(
                snapshot: quotaAsync.value,
                statusWarnText: memory.quotaWarnText,
              ),

              const Divider(height: 32),

              // ── 连接测试（FR-505，见向导）──
              ListTile(
                leading: const Icon(Icons.network_check),
                title: const Text('测试连接'),
                subtitle: const Text('往返延迟与目录权限检查'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/sync/guide'),
              ),

              // ── 同步维护：云端孤儿清理（docs/04 §7.1 规则 4）──
              // 未配置时点击引导去配置；已配置进入清理页。
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('云端孤儿清理'),
                subtitle: const Text('列出云端无书目的正文文件，确认后逐个删除'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _openOrphanCleanup(context, configAsync),
              ),

              // ── 危险区：清除凭据（FR-504 整体清除语义）──
              ListTile(
                leading: Icon(
                  Icons.key_off,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  '清除凭据',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text('删除账号、应用密码与设备关联信息'),
                onTap: () => _confirmClearCredentials(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 孤儿清理入口：未配置 → 引导去配置；已配置 → 推入清理页。
  void _openOrphanCleanup(
    BuildContext context,
    AsyncValue<SyncConfigSummary?> configAsync,
  ) {
    if (configAsync.value != null) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const CloudOrphanCleanupPage()),
      );
    } else {
      context.push('/sync/guide');
    }
  }

  Future<void> _confirmClearCredentials(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除凭据？'),
        content: const Text(
          '将删除安全存储中的账号与应用密码，'
          '本地书库与阅读进度不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(syncFacadeProvider).clearCredentials();
    }
  }
}

/// 配额面板：月度上行/下行进度条 + 顶部常驻警示条（80%/100%）+ 越权放行
/// （FR-407/docs/04 §8.3）。闸门逻辑在引擎/闸门层，这里只做 UI 呈现与入口。
class _QuotaPanel extends ConsumerWidget {
  const _QuotaPanel({required this.snapshot, this.statusWarnText});

  final QuotaSnapshot? snapshot;

  /// 内存侧告警文案（同步过程中实时上报；快照未告警时兜底展示）。
  final String? statusWarnText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final snap = snapshot;
    if (snap == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('配额信息不可用（未配置后端）'),
      );
    }
    final override = ref.watch(syncPreferencesProvider).quotaOverride;

    // 顶部常驻警示条（docs/04 §8.3 的 80% 提醒入口）：
    // - ≥80%（未达 100%）→ 80% 文案（自动下载已暂停、元数据不受影响）；
    // - 100% → 正文挂起文案（引导到下方越权放行）；
    // - 快照未告警 → 内存侧实时告警兜底（同步轮次中上报）。
    final String? bannerText;
    if (snap.downExceeded) {
      bannerText = '正文传输已全部挂起，可在下方越权继续（将消耗坚果云额度）';
    } else if (snap.warn) {
      bannerText = '坚果云流量已用超 80%，自动下载已暂停；元数据同步不受影响';
    } else {
      bannerText = statusWarnText;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (bannerText != null)
            _QuotaWarnBanner(text: bannerText, severe: snap.downExceeded),
          Text('本月流量（${snap.month ?? '-'}）', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          _QuotaBar(
            label: '上行',
            used: snap.upBytes,
            ratio: snap.upRatio.clamp(0.0, 1.0),
          ),
          const SizedBox(height: 8),
          _QuotaBar(
            label: '下行',
            used: snap.downBytes,
            ratio: snap.downRatio.clamp(0.0, 1.0),
          ),
          // 100% 挂起 × 越权开关（quotaOverride）关联展示（docs/04 §8.3）。
          if (snap.downExceeded && !override)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => _confirmOverride(context, ref),
                child: const Text('继续下载（流量已超限）'),
              ),
            )
          else if (snap.downExceeded && override)
            Row(
              children: [
                Icon(
                  Icons.lock_open,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '已越权放行：本月正文下载将继续，额度管控次月自动恢复',
                    style: TextStyle(
                      color: theme.colorScheme.outline,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => ref
                      .read(syncPreferencesProvider.notifier)
                      .setQuotaOverride(false),
                  child: const Text('恢复闸门'),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// 越权放行：明确二次确认（docs/04 §8.3）。
  Future<void> _confirmOverride(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本月流量已达上限'),
        content: const Text(
          '继续下载将占用坚果云超额流量，'
          '可能产生额外费用或被服务方限制。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续下载'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(syncPreferencesProvider.notifier).setQuotaOverride(true);
    }
  }
}

/// 顶部常驻警示条（80% 提醒 / 100% 挂起；severe 用更重的描边强调）。
class _QuotaWarnBanner extends StatelessWidget {
  const _QuotaWarnBanner({required this.text, required this.severe});

  final String text;
  final bool severe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: severe
            ? Border.all(color: theme.colorScheme.error, width: 1)
            : null,
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: theme.colorScheme.onErrorContainer,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单行配额进度条。
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({
    required this.label,
    required this.used,
    required this.ratio,
  });

  final String label;
  final int used;
  final double ratio;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 96,
          child: Text(
            '${humanizeBytes(used)}（${(ratio * 100).round()}%）',
            textAlign: TextAlign.right,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
