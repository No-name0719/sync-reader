/// 批量导入确认页（FR-109）：展示可导入文件清单（相对路径 / 格式 / 大小）、
/// "已存在"去重标记、全选 / 反选、底部合计与"导入选中"。
///
/// 打开即扫描 + 哈希分析（渐进出结果，见 [BatchImportController]）；
/// 导入期间行内交互冻结、显示进度；结束后弹汇总对话框，关闭即返回书库
/// （书库列表由 drift watch 自动刷新，无需手动通知）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/format_utils.dart';
import 'batch_import_controller.dart';

/// 批量导入确认页。
class BatchImportConfirmationPage extends ConsumerStatefulWidget {
  const BatchImportConfirmationPage({super.key, required this.directoryPath});

  /// 用户选定的扫描根目录（绝对路径）。
  final String directoryPath;

  @override
  ConsumerState<BatchImportConfirmationPage> createState() =>
      _BatchImportConfirmationPageState();
}

class _BatchImportConfirmationPageState
    extends ConsumerState<BatchImportConfirmationPage> {
  @override
  void initState() {
    super.initState();
    // build 之外触发首轮扫描；导入进行中由控制器防重入兜底。
    Future.microtask(() {
      if (!mounted) return; // 微任务执行前页面已被退出：放弃扫描。
      ref
          .read(batchImportControllerProvider.notifier)
          .startScan(widget.directoryPath);
    });
  }

  /// 导入结束（importing → done）弹汇总对话框；关闭后返回书库。
  void _onStateChanged(BatchImportState? prev, BatchImportState next) {
    if (next.phase != BatchImportPhase.done ||
        prev?.phase != BatchImportPhase.importing) {
      return;
    }
    final summary = next.summary;
    if (!mounted) return;
    if (summary == null) {
      // 导入启动级失败（如存储目录不可写）：提示后留在本页可重试。
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(next.errorMessage ?? '导入失败')));
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('批量导入完成'),
        content: Text(batchImportSummaryMessage(summary)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop(); // 关对话框
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop(); // 返回书库
              }
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(batchImportControllerProvider, _onStateChanged);
    final state = ref.watch(batchImportControllerProvider);
    final analyzing = state.phase == BatchImportPhase.analyzing;
    final frozen = state.importing; // 导入中冻结勾选交互（防重入）。

    return Scaffold(
      appBar: AppBar(
        title: const Text('批量导入'),
        actions: [
          TextButton(
            onPressed: frozen || state.candidates.isEmpty
                ? null
                : () => ref
                      .read(batchImportControllerProvider.notifier)
                      .selectAll(),
            child: const Text('全选'),
          ),
          TextButton(
            onPressed: frozen || state.candidates.isEmpty
                ? null
                : () => ref
                      .read(batchImportControllerProvider.notifier)
                      .invertSelection(),
            child: const Text('反选'),
          ),
        ],
      ),
      body: switch (state.phase) {
        BatchImportPhase.idle || BatchImportPhase.scanning => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('正在扫描文件夹…'),
            ],
          ),
        ),
        _ => Column(
          children: [
            if (analyzing)
              LinearProgressIndicator(
                value: state.candidates.isEmpty
                    ? null
                    : state.analyzedCount / state.candidates.length,
              ),
            if (state.importing) ...[
              LinearProgressIndicator(
                value: state.progress == null || state.progress!.total == 0
                    ? null
                    : state.progress!.completed / state.progress!.total,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    state.progress == null
                        ? '准备导入…'
                        : '正在导入（${state.progress!.completed}/'
                              '${state.progress!.total}）：'
                              '${state.progress!.currentName}',
                  ),
                ),
              ),
            ],
            if (state.truncated || state.skippedCount > 0 || analyzing)
              _NoticeBar(
                text: [
                  if (analyzing)
                    '去重分析中 ${state.analyzedCount}/${state.candidates.length}…',
                  if (state.truncated) '文件数超过上限，扫描已截断，清单可能不完整',
                  if (state.skippedCount > 0)
                    '${state.skippedCount} 个条目无法访问，已跳过',
                ].join('；'),
              ),
            if (state.errorMessage != null)
              _NoticeBar(text: state.errorMessage!, error: true),
            Expanded(
              child: state.candidates.isEmpty
                  ? const Center(child: Text('该文件夹下没有可导入的书籍文件'))
                  : ListView.builder(
                      itemCount: state.candidates.length,
                      itemBuilder: (context, index) {
                        final candidate = state.candidates[index];
                        return _CandidateTile(
                          candidate: candidate,
                          // 行键含 index：测试与复用定位稳定。
                          key: ValueKey('batch-candidate-$index'),
                          enabled: !frozen,
                          onToggle: () => ref
                              .read(batchImportControllerProvider.notifier)
                              .toggle(index),
                        );
                      },
                    ),
            ),
            _BottomBar(
              state: state,
              onImport: () => ref
                  .read(batchImportControllerProvider.notifier)
                  .importSelected(),
            ),
          ],
        ),
      },
    );
  }
}

/// 顶部提示条（截断 / 跳过 / 分析进度 / 错误）。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text, this.error = false});

  final String text;

  /// true 时按错误色显示（目录不可访问等）。
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: error ? theme.colorScheme.errorContainer : theme.hoverColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: SizedBox(
          width: double.infinity,
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: error
                  ? theme.colorScheme.onErrorContainer
                  : theme.colorScheme.outline,
            ),
          ),
        ),
      ),
    );
  }
}

/// 清单行：勾选框 + 相对路径 + 格式 / 大小 / 去重标记。
class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    required this.candidate,
    required this.enabled,
    required this.onToggle,
    super.key,
  });

  final ImportCandidate candidate;

  /// false 时勾选框禁用（导入进行中冻结交互）。
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final file = candidate.file;
    return CheckboxListTile(
      value: candidate.selected,
      onChanged: enabled ? (_) => onToggle() : null,
      controlAffinity: ListTileControlAffinity.leading,
      dense: true,
      title: Row(
        children: [
          Flexible(
            child: Text(
              file.relativePath,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (candidate.isDuplicate) ...[
            const SizedBox(width: 6),
            // 去重标记（FR-109：已在书库的默认不勾并标注）。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '已存在',
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        candidate.duplicateOf == null
            ? '${file.ext.toUpperCase()} · ${humanizeBytes(file.sizeBytes)}'
            : candidate.duplicateInBatch
            ? '与本批 ${candidate.duplicateOf} 重复 · '
                  '${humanizeBytes(file.sizeBytes)}'
            : '库内已有《${candidate.duplicateOf}》 · '
                  '${humanizeBytes(file.sizeBytes)}',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 底部合计与主操作（导入中禁用，防重复触发）。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.state, required this.onImport});

  final BatchImportState state;

  /// 触发导入选中（回调方负责调用控制器）。
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedCandidates.length;
    final canImport = state.phase == BatchImportPhase.ready && selected > 0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                selected == 0
                    ? '未选择任何文件'
                    : '已选 $selected 本 · ${humanizeBytes(state.selectedBytes)}',
              ),
            ),
            FilledButton.icon(
              onPressed: canImport ? onImport : null,
              icon: const Icon(Icons.download),
              label: Text(state.importing ? '导入中…' : '导入选中（$selected）'),
            ),
          ],
        ),
      ),
    );
  }
}
