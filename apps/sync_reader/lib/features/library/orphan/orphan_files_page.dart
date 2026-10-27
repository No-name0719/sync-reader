/// 游离文件管理页（FR-408）：本地孤儿正文文件的清单、恢复挂回与彻底删除。
///
/// 纯本地语义（FR-601 本地优先）：未配置同步时本面板完全可用。挂回成功
/// 后云端收敛是自动的（下次同步走哈希去重或 tombstone 复活路径），进度
/// 在同步时尽力恢复；彻底删除需二次确认（本地文件不可恢复）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/format_utils.dart';
import 'orphan_book_file.dart';
import 'orphan_panel_controller.dart';

/// 游离文件管理页。
class OrphanFilesPage extends ConsumerWidget {
  const OrphanFilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(orphanPanelControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('游离文件管理')),
      body: Column(
        children: [
          if (state.errorMessage != null)
            Material(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: Text(
                    state.errorMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: switch (state) {
              _ when state.orphans.isEmpty && state.scanning => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('正在扫描游离文件…'),
                  ],
                ),
              ),
              _ when state.orphans.isEmpty => const _EmptyView(),
              _ => RefreshIndicator(
                onRefresh: () =>
                    ref.read(orphanPanelControllerProvider.notifier).refresh(),
                child: ListView.builder(
                  // 物理始终可滚动：空错误横幅切换时列表高度稳定。
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: state.orphans.length,
                  itemBuilder: (context, index) {
                    final orphan = state.orphans[index];
                    return _OrphanTile(
                      key: ValueKey(orphan.path),
                      orphan: orphan,
                      title: ref
                          .read(orphanPanelControllerProvider.notifier)
                          .displayTitle(orphan),
                      frozen: state.frozen,
                      onRestore: () => _restore(context, ref, orphan),
                      onDelete: () => _confirmDelete(context, ref, orphan),
                    );
                  },
                ),
              ),
            },
          ),
        ],
      ),
    );
  }

  /// 恢复挂回：库内已有同 hash 书 → 提示冗余；否则提示挂回成功
  /// （进度将在同步时尽力恢复）。
  Future<void> _restore(
    BuildContext context,
    WidgetRef ref,
    OrphanBookFile orphan,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await ref
        .read(orphanPanelControllerProvider.notifier)
        .restore(orphan);
    if (result == null) return;
    if (result.isDuplicate) {
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 5),
          content: Text(
            '书库已有同内容书籍《${result.duplicateOf}》，未重复挂回；'
            '该游离文件已冗余，可在列表中彻底删除',
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(seconds: 5),
        content: Text('挂回成功，进度将在同步时尽力恢复'),
      ),
    );
  }

  /// 彻底删除：二次确认（明确"本地文件将被永久删除，不可恢复"）后才执行。
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    OrphanBookFile orphan,
  ) async {
    final controller = ref.read(orphanPanelControllerProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('彻底删除'),
        content: Text(
          '《${controller.displayTitle(orphan)}》的本地文件将被永久删除，'
          '不可恢复。确定删除？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(orphanPanelControllerProvider.notifier)
        .delete(orphan);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(content: Text('已删除《${orphan.stem}》的本地文件')),
      );
    }
  }
}

/// 空态：说明游离文件来源（其他设备删除的书会保留本地正文）。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('没有游离文件', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '其他设备删除的书会在这里保留本地正文，\n'
            '可重新挂回书库或彻底删除；正常情况下此列表为空',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 游离文件行：标题（懒解析书名/主干）+ 格式/大小/文件名 + 挂回/删除操作。
class _OrphanTile extends StatelessWidget {
  const _OrphanTile({
    required this.orphan,
    required this.title,
    required this.frozen,
    required this.onRestore,
    required this.onDelete,
    super.key,
  });

  final OrphanBookFile orphan;

  /// 展示标题（懒解析书名，解析中/失败为文件名主干）。
  final String title;

  /// true 时操作按钮禁用（扫描/操作进行中，防重入）。
  final bool frozen;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          orphan.formatLabel,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${orphan.shapeLabel} · ${orphan.formatLabel} · '
        '${humanizeBytes(orphan.sizeBytes)} · ${orphan.fileName}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: frozen ? null : onRestore,
            child: const Text('挂回'),
          ),
          IconButton(
            tooltip: '彻底删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: frozen ? null : onDelete,
          ),
        ],
      ),
    );
  }
}
