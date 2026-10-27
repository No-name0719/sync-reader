/// 云端孤儿清理页（FR-408 / docs/04 §7.1 规则 4）：
///
/// - 进入即拉取孤儿清单（`books/` 下无 meta 引用的正文文件）；
/// - 逐文件确认删除（手动、可暂停；删除流量计入坚果云额度）；
/// - 批量清理按"逐文件顺序执行 + 可暂停"语义实现：每个文件删除前都视为
///   已在总确认中确认，暂停后停止循环（已删的保留），可继续或收尾；
/// - 隐私（docs/04 §9）：孤儿文件名只有 `{bookId}.{ext}`，不含 meta 内容，
///   界面与日志天然脱敏；
/// - 每次删除后使 [quotaSnapshotProvider] 失效，保持配额面板展示准确。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_core/sync_core.dart';

import '../../../shared/format_utils.dart';
import '../sync_facade.dart';
import '../sync_status.dart';

/// 云端孤儿清理页（经同步设置页入口以 MaterialPageRoute 推入）。
class CloudOrphanCleanupPage extends ConsumerStatefulWidget {
  const CloudOrphanCleanupPage({super.key});

  @override
  ConsumerState<CloudOrphanCleanupPage> createState() =>
      _CloudOrphanCleanupPageState();
}

final class _CloudOrphanCleanupPageState
    extends ConsumerState<CloudOrphanCleanupPage> {
  bool _loading = true;

  /// 未配置同步（facade 返回 null）→ 引导去配置。
  bool _unconfigured = false;

  /// 清单阶段失败（网络等）→ 错误态 + 重试。
  SyncError? _listingError;

  /// 当前孤儿清单（删除成功即移除；删除失败保留并标错）。
  List<CloudBookFile> _orphans = const <CloudBookFile>[];

  /// 文件名 → 最近一次删除失败的分类文案（行内红字展示，可重试）。
  final Map<String, String> _rowErrors = <String, String>{};

  // ── 批量清理状态（逐文件执行 + 可暂停，docs/04 §7.1 规则 4）──

  /// 批量会话进行中（运行或暂停挂起；汇总展示后结束）。
  bool _batchActive = false;

  /// 暂停标志：当前文件删完后停止循环。
  bool _paused = false;

  /// 本轮批量开始时的总数（进度分母）。
  int _batchTotal = 0;

  /// 已成功删除数（重试成功不重复计数）。
  int _batchDeleted = 0;

  /// 尚未成功的文件数（失败 + 待处理不计，只计"已尝试且失败"）。
  int _batchFailed = 0;

  @override
  void initState() {
    super.initState();
    // 初始 _loading = true 渲染加载态；此处只拉数据，完成后再 setState。
    _loadListing();
  }

  /// 重试：回到加载态后重新拉取。
  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _listingError = null;
      _unconfigured = false;
    });
    await _loadListing();
  }

  /// 拉取孤儿清单（未配置 → null；清单错误 → 带错误的空清单）。
  Future<void> _loadListing() async {
    final listing = await ref.read(syncFacadeProvider).listCloudOrphans();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (listing == null) {
        _unconfigured = true;
        _orphans = const [];
      } else {
        _listingError = listing.error;
        _orphans = List.of(listing.orphans);
      }
    });
  }

  int get _totalBytes => _orphans.fold(0, (sum, file) => sum + file.sizeBytes);

  // ── 单文件删除 ────────────────────────────────────────────────────────

  Future<void> _deleteOne(CloudBookFile file) async {
    final confirmed = await _confirmDialog(
      title: '删除孤儿文件？',
      content:
          '将删除云端文件 ${file.name}'
          '（${humanizeBytes(file.sizeBytes)}）。'
          '该文件在云端已无对应书目，删除不影响任何设备上的书库。',
      confirmLabel: '删除',
    );
    if (confirmed != true || !mounted) return;
    final error = await ref
        .read(syncFacadeProvider)
        .deleteCloudOrphan(file.name);
    if (!mounted) return;
    if (error == null) {
      setState(() {
        _orphans.removeWhere((e) => e.name == file.name);
        _rowErrors.remove(file.name);
      });
      // 删除也产生少量请求流量：刷新配额展示（docs/04 §8.3）。
      ref.invalidate(quotaSnapshotProvider);
    } else {
      // 失败保留该行，snackbar 给出分类原因（FR-406）。
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('删除失败：${syncErrorText(error)}')));
    }
  }

  // ── 批量清理（逐文件顺序执行 + 可暂停）────────────────────────────────

  Future<void> _startBatch() async {
    final confirmed = await _confirmDialog(
      title: '全部清理？',
      content:
          '共 ${_orphans.length} 个文件，合计 ${humanizeBytes(_totalBytes)}。'
          '将逐个删除（流量计入坚果云），可随时暂停。',
      confirmLabel: '全部清理',
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _batchActive = true;
      _paused = false;
      _batchTotal = _orphans.length;
      _batchDeleted = 0;
      _batchFailed = 0;
    });
    await _runBatchLoop();
  }

  /// 顺序删除剩余孤儿；每删一个让 UI 刷新一次；暂停/失败不打断其余文件。
  Future<void> _runBatchLoop() async {
    setState(() {
      _batchActive = true;
      _paused = false;
    });
    final pending = List.of(_orphans);
    for (final target in pending) {
      if (!mounted || _paused) break;
      final retried = _rowErrors.containsKey(target.name);
      final error = await ref
          .read(syncFacadeProvider)
          .deleteCloudOrphan(target.name);
      if (!mounted) return;
      setState(() {
        if (error == null) {
          _orphans.removeWhere((e) => e.name == target.name);
          _rowErrors.remove(target.name);
          _batchDeleted++;
          if (retried) _batchFailed--;
        } else if (!retried) {
          _batchFailed++;
          _rowErrors[target.name] = syncErrorText(error);
        }
      });
      ref.invalidate(quotaSnapshotProvider);
    }
    if (!mounted) return;
    // 暂停挂起时会话保持活跃（条带显示"继续"）；跑完才结束并汇总。
    if (_paused) return;
    setState(() => _batchActive = false);
    _showBatchSummary();
  }

  void _pauseBatch() => setState(() => _paused = true);

  void _resumeBatch() {
    _runBatchLoop();
  }

  void _showBatchSummary() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理完成'),
        content: Text(
          _batchFailed == 0
              ? '已删除 $_batchDeleted 个孤儿文件。'
              : '已删除 $_batchDeleted 个，失败 $_batchFailed 个'
                    '（失败文件仍保留在列表中，可重试）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // ── 通用确认对话框（逐文件确认语义，docs/04 §7.1 规则 4）──────────────

  Future<bool?> _confirmDialog({
    required String title,
    required String content,
    required String confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  // ── 界面 ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('云端孤儿清理'),
        actions: [
          TextButton(
            // 批量进行中（含暂停挂起）禁用入口，避免并发两轮清理。
            onPressed: _canStartBatch ? _startBatch : null,
            child: const Text('全部清理'),
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  bool get _canStartBatch =>
      !_loading &&
      !_unconfigured &&
      _listingError == null &&
      !_batchActive &&
      _orphans.isNotEmpty;

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_unconfigured) {
      return _CenteredHint(
        icon: Icons.cloud_off_outlined,
        title: '云端同步未配置',
        subtitle: '配置坚果云后即可清理云端残留的孤儿文件',
        action: FilledButton(
          onPressed: () => context.push('/sync/guide'),
          child: const Text('去配置'),
        ),
      );
    }
    final listingError = _listingError;
    if (listingError != null) {
      return _CenteredHint(
        icon: Icons.error_outline,
        title: '孤儿清单获取失败',
        subtitle: syncErrorText(listingError),
        action: OutlinedButton(onPressed: _reload, child: const Text('重试')),
      );
    }
    if (_orphans.isEmpty && !_batchActive) {
      return const _CenteredHint(
        icon: Icons.check_circle_outline,
        title: '云端没有孤儿文件',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 ${_orphans.length} 个文件 · 合计 ${humanizeBytes(_totalBytes)}',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '这些正文文件在云端已无对应书目（通常因删除后残留）。'
                '删除不影响任何设备上的书库。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        if (_batchActive)
          _BatchProgressStrip(
            total: _batchTotal,
            deleted: _batchDeleted,
            failed: _batchFailed,
            paused: _paused,
            onPause: _pauseBatch,
            onResume: _resumeBatch,
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _orphans.length,
            itemBuilder: (context, index) {
              final file = _orphans[index];
              final rowError = _rowErrors[file.name];
              return ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(file.name),
                subtitle: rowError == null
                    ? null
                    : Text(
                        rowError,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      humanizeBytes(file.sizeBytes),
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: '删除',
                      // 批量会话进行中（含暂停挂起）禁用单文件删除。
                      onPressed: _batchActive ? null : () => _deleteOne(file),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 居中提示（空态/未配置/错误态共用）。
class _CenteredHint extends StatelessWidget {
  const _CenteredHint({
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// 批量清理进度条（已删/总数 + 暂停/继续）。
class _BatchProgressStrip extends StatelessWidget {
  const _BatchProgressStrip({
    required this.total,
    required this.deleted,
    required this.failed,
    required this.paused,
    required this.onPause,
    required this.onResume,
  });

  final int total;
  final int deleted;
  final int failed;
  final bool paused;
  final VoidCallback onPause;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settled = (deleted + failed).clamp(0, total);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      margin: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paused
                      ? '已暂停：已删 $deleted / $total'
                      : '正在清理：已删 $deleted / $total',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: total == 0 ? null : settled / total,
                  minHeight: 4,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: paused ? onResume : onPause,
            child: Text(paused ? '继续' : '暂停'),
          ),
        ],
      ),
    );
  }
}
