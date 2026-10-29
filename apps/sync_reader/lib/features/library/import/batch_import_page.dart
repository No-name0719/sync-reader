/// 批量导入页（FR-109 + docs/10 §4.2 导入段 / §4.8 批量导入页保留，A13/A16）：
/// 选文件夹 → 递归扫描 → 清单确认 → 导入，页内常驻进度与完成汇总。
///
/// 视觉对齐原型「批量导入」屏（ui_prototype/index.html 屏 7，content-inner
/// 860px）：顶部说明 + 「选择文件夹」主按钮；清单卡（勾选框 + 格式徽标 +
/// 相对路径 + 大小，重复项标注「库内已有」）；底部操作条（「同时上传到云端」
/// 开关（Q18 默认开，关上出现不上传提示行）+ 已选合计 + 导入主按钮）。
///
/// 状态机在 [BatchImportController]（只读复用）：打开先选目录，选定后
/// 扫描 + 哈希分析渐进出结果；导入期间行内交互冻结；完成后页内汇总
/// （成功 / 重复 / 失败清单，失败列原因），「完成」返回书库首页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/design_tokens.dart';
import '../../../shared/format_utils.dart';
import 'batch_import_controller.dart';
import 'book_import_service.dart' show ImportProgress, ImportSummary;

/// 批量导入页（shell 内路由 `/tools/batch-import`，A16）。
class BatchImportPage extends ConsumerStatefulWidget {
  const BatchImportPage({super.key});

  @override
  ConsumerState<BatchImportPage> createState() => _BatchImportPageState();
}

class _BatchImportPageState extends ConsumerState<BatchImportPage> {
  /// 「同时上传到云端」开关（Q18：默认开）。
  bool _uploadToCloud = true;

  /// 目录选择器失败信息（平台通道不可用等；扫描错误走控制器 errorMessage）。
  String? _pickerError;

  @override
  void initState() {
    super.initState();
    // 从书库分裂按钮带"进行中会话"进入时无目录可选：保持 idle。
  }

  /// 选择文件夹并开始扫描（用户点主按钮触发）。
  Future<void> _pickAndScan() async {
    final picker = ref.read(directoryPickerProvider);
    final String? directoryPath;
    try {
      directoryPath = await picker.pickDirectory();
    } catch (e) {
      if (!mounted) return;
      setState(() => _pickerError = '无法打开文件夹选择器：$e');
      return;
    }
    if (directoryPath == null) return; // 用户取消：静默返回。
    if (!mounted) return;
    setState(() => _pickerError = null);
    await ref
        .read(batchImportControllerProvider.notifier)
        .startScan(directoryPath);
  }

  @override
  Widget build(BuildContext context) {
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
      body: state.directoryPath == null && state.phase == BatchImportPhase.idle
          ? _ChooserCard(onPick: _pickAndScan, error: _pickerError)
          : _PipelineView(
              state: state,
              analyzing: analyzing,
              frozen: frozen,
              uploadToCloud: _uploadToCloud,
              onUploadChanged: frozen
                  ? null
                  : (value) => setState(() => _uploadToCloud = value),
              onToggle: (index) => ref
                  .read(batchImportControllerProvider.notifier)
                  .toggle(index),
              onImport: () => ref
                  .read(batchImportControllerProvider.notifier)
                  .importSelected(uploadToCloud: _uploadToCloud),
            ),
    );
  }
}

/// 首屏（未选目录）：说明 + 「选择文件夹」主按钮。
class _ChooserCard extends StatelessWidget {
  const _ChooserCard({required this.onPick, this.error});

  final VoidCallback onPick;

  /// 目录选择器失败提示（平台通道不可用等）。
  final String? error;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.s6),
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: t.border),
                  ),
                  child: Column(
                    children: [
                      Icon(
                        Icons.folder_open_outlined,
                        size: 40,
                        color: t.brand,
                      ),
                      const SizedBox(height: AppSpacing.s3),
                      Text('批量导入（文件夹）', style: t.h3),
                      const SizedBox(height: AppSpacing.s2),
                      Text(
                        '选择一个文件夹，SyncReader 将递归扫描其中所有支持的'
                        '书籍文件（txt / epub / md / pdf），列出清单供你确认后'
                        '一次导入。已在本库的书会按内容去重标注。',
                        style: t.sm.copyWith(color: t.text2),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.s5),
                      FilledButton.icon(
                        key: const ValueKey('batch-pick-folder'),
                        onPressed: onPick,
                        icon: const Icon(Icons.folder_open_outlined, size: 18),
                        label: const Text('选择文件夹'),
                      ),
                    ],
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: AppSpacing.s3),
                  _NoticeBar(text: error!, error: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 流程视图：分析卡 / 清单卡 / 底部操作条 / 完成汇总。
class _PipelineView extends StatelessWidget {
  const _PipelineView({
    required this.state,
    required this.analyzing,
    required this.frozen,
    required this.uploadToCloud,
    required this.onUploadChanged,
    required this.onToggle,
    required this.onImport,
  });

  final BatchImportState state;
  final bool analyzing;
  final bool frozen;
  final bool uploadToCloud;
  final ValueChanged<bool>? onUploadChanged;
  final void Function(int index) onToggle;

  /// 触发导入选中（回调方负责调用控制器并带上传开关）。
  final Future<ImportSummary?> Function() onImport;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 顶部提示区（保持固定，不随清单滚动）──
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.s6,
                      AppSpacing.s4,
                      AppSpacing.s6,
                      0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (state.importing)
                          _ImportProgressStrip(progress: state.progress),
                        if (analyzing) _AnalyzingCard(state: state),
                        if (state.truncated ||
                            state.skippedCount > 0 ||
                            state.errorMessage != null)
                          _NoticeBar(
                            text: [
                              if (state.truncated) '文件数超过上限，扫描已截断，清单可能不完整',
                              if (state.skippedCount > 0)
                                '${state.skippedCount} 个条目无法访问，已跳过',
                              if (state.errorMessage != null)
                                state.errorMessage!,
                            ].join('；'),
                            error: state.errorMessage != null,
                          ),
                        if (state.phase == BatchImportPhase.done &&
                            state.summary != null)
                          _DoneSummaryCard(summary: state.summary!),
                      ],
                    ),
                  ),
                  // ── 清单卡 ──
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s6,
                        AppSpacing.s3,
                        AppSpacing.s6,
                        AppSpacing.s3,
                      ),
                      child: _ListCard(
                        state: state,
                        frozen: frozen,
                        onToggle: onToggle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // ── 底部操作条（开贴合页底，宽度跟内容区对齐）──
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: _BottomBar(
              state: state,
              uploadToCloud: uploadToCloud,
              onUploadChanged: onUploadChanged,
              onImport: onImport,
            ),
          ),
        ),
      ],
    );
  }
}

/// 清单卡：卡头（目录 + N 个文件）+ 文件行列表。
class _ListCard extends StatelessWidget {
  const _ListCard({
    required this.state,
    required this.frozen,
    required this.onToggle,
  });

  final BatchImportState state;
  final bool frozen;
  final void Function(int index) onToggle;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final scanning =
        state.phase == BatchImportPhase.scanning ||
        state.phase == BatchImportPhase.idle;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 卡头：目录路径 + 文件数胶囊（原型 card-head）。
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s4,
              AppSpacing.s5,
              AppSpacing.s3,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    state.directoryPath ?? '',
                    style: t.sm.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                _CountPill(text: '${state.candidates.length} 个文件'),
              ],
            ),
          ),
          Divider(height: 1, color: t.border),
          Expanded(
            child: scanning
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在扫描文件夹…'),
                      ],
                    ),
                  )
                : state.candidates.isEmpty
                ? Center(child: Text('该文件夹下没有可导入的书籍文件', style: t.sm))
                : ListView.builder(
                    itemCount: state.candidates.length,
                    itemBuilder: (context, index) {
                      final candidate = state.candidates[index];
                      return _CandidateTile(
                        candidate: candidate,
                        // 行键含 index：测试与复用定位稳定。
                        key: ValueKey('batch-candidate-$index'),
                        enabled: !frozen,
                        onToggle: () => onToggle(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 数量胶囊（原型 .pill：中性小胶囊）。
class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: t.surface3,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Center(child: Text(text, style: t.micro.copyWith(fontSize: 11.5))),
    );
  }
}

/// 分析卡（原型屏 7 顶部卡）：去重分析中 + 渐进计数 + 线性进度。
class _AnalyzingCard extends StatelessWidget {
  const _AnalyzingCard({required this.state});

  final BatchImportState state;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final total = state.candidates.length;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.sync, size: 17, color: t.brand),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  '正在分析文件内容以去重…',
                  style: t.sm.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text('${state.analyzedCount} / $total', style: t.tertiary),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: LinearProgressIndicator(
              value: total == 0 ? null : state.analyzedCount / total,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 导入进度条带（A13：常驻线性进度 + 当前文件名，原型 .batch-strip）。
class _ImportProgressStrip extends StatelessWidget {
  const _ImportProgressStrip({required this.progress});

  final ImportProgress? progress;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  progress == null
                      ? '准备导入…'
                      : '正在导入（${progress!.completed}/${progress!.total}）：'
                            '${progress!.currentName}',
                  style: t.sm.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: LinearProgressIndicator(
              value: progress == null || progress!.total == 0
                  ? null
                  : progress!.completed / progress!.total,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 完成汇总卡（A13：常驻汇总，成功 / 重复 / 失败清单，失败列原因）。
class _DoneSummaryCard extends StatelessWidget {
  const _DoneSummaryCard({required this.summary});

  final ImportSummary summary;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final lines = <(String, Color?)>[
      (
        '成功 ${summary.imported.length} 本'
            '${summary.duplicates.isEmpty ? '' : ' · 跳过重复 ${summary.duplicates.length} 本'}'
            '${summary.failures.isEmpty ? '' : ' · 失败 ${summary.failures.length} 本'}',
        t.text2,
      ),
      for (final entry in summary.duplicates.entries)
        ('《${entry.value}》已存在，已复用原条目（${entry.key}）', t.text3),
      for (final entry in summary.failures.entries)
        ('${entry.key} 导入失败：${entry.value}', t.danger),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 18, color: t.success),
              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Text('批量导入完成', style: t.h3)),
              FilledButton(
                key: const ValueKey('batch-done'),
                onPressed: () => context.go('/'),
                child: const Text('完成'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          for (final (text, color) in lines)
            Text(text, style: t.caption.copyWith(color: color ?? t.text2)),
        ],
      ),
    );
  }
}

/// 顶部提示条（截断 / 跳过 / 错误）。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text, this.error = false});

  final String text;

  /// true 时按错误色显示（目录不可访问等）。
  final bool error;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s3),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: error ? t.dangerSoft : t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text(
        text,
        style: (error ? t.caption.copyWith(color: t.danger) : t.tertiary),
      ),
    );
  }
}

/// 清单行：勾选框 + 格式徽标 + 相对路径 + 大小（+ 重复标注）。
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
    final t = context.appTokens;
    final file = candidate.file;
    final note = candidate.duplicateOf == null
        ? null
        : candidate.duplicateInBatch
        ? '与本批 ${candidate.duplicateOf} 重复'
        : '库内已有《${candidate.duplicateOf}》';
    return InkWell(
      onTap: enabled ? onToggle : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s5,
          vertical: AppSpacing.s3,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: candidate.selected,
              onChanged: enabled ? (_) => onToggle() : null,
            ),
            const SizedBox(width: AppSpacing.s2),
            _FormatChip(ext: file.ext),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.relativePath,
                    style: t.body.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          '${file.ext.toUpperCase()} · ${humanizeBytes(file.sizeBytes)}',
                          style: t.tertiary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (note != null) ...[
                        const _SubtleDot(),
                        Flexible(
                          child: Text(
                            note,
                            style: t.tertiary.copyWith(color: t.warn),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 次级信息分隔点（原型 .fs .dot）。
class _SubtleDot extends StatelessWidget {
  const _SubtleDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: context.appTokens.text3,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 格式徽标（原型 .fmt-chip：38×48 圆角块，按格式着色）。
class _FormatChip extends StatelessWidget {
  const _FormatChip({required this.ext});

  final String ext;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    // 原型 data-fmt 配色：EPUB 绿 / TXT 墨褐 / PDF 红 / MD 蓝；未知格式走中性。
    final color = switch (ext.toUpperCase()) {
      'EPUB' => const Color(0xFF2F6D4F),
      'TXT' => const Color(0xFF6B6257),
      'PDF' => const Color(0xFFA04A3C),
      'MD' => const Color(0xFF3F5B8A),
      _ => const Color(0xFF6B6257),
    };
    return Container(
      width: 38,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        ext.toUpperCase(),
        style: t.micro.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          letterSpacing: 0.02,
        ),
      ),
    );
  }
}

/// 底部操作条：「同时上传到云端」开关（+ 关上提示行）+ 已选合计 + 导入主按钮。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.state,
    required this.uploadToCloud,
    required this.onUploadChanged,
    required this.onImport,
  });

  final BatchImportState state;
  final bool uploadToCloud;
  final ValueChanged<bool>? onUploadChanged;

  /// 触发导入选中。
  final Future<ImportSummary?> Function() onImport;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final total = state.candidates.length;
    final selected = state.selectedCandidates.length;
    final canImport = state.phase == BatchImportPhase.ready && selected > 0;
    final done = state.phase == BatchImportPhase.done && state.summary == null;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s6,
          AppSpacing.s2,
          AppSpacing.s6,
          AppSpacing.s3,
        ),
        decoration: BoxDecoration(color: t.bg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 「同时上传到云端」开关行（Q18 默认开；导入中冻结）。
            Row(
              children: [
                Switch(value: uploadToCloud, onChanged: onUploadChanged),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    '同时上传到云端',
                    style: t.sm.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            // 关上时的提示行（§4.2：不上传的语义说清）。
            if (!uploadToCloud)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.s6 + 12,
                  bottom: AppSpacing.s1,
                ),
                child: Text(
                  '不上传：不消耗上行流量，其它设备看不到这几本书',
                  style: t.caption.copyWith(color: t.text2),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    selected == 0
                        ? '未选择任何文件'
                        : '已选 $selected / $total 本 · '
                              '${humanizeBytes(state.selectedBytes)}',
                    style: t.sm.copyWith(color: t.text2),
                  ),
                ),
                if (done)
                  FilledButton(
                    key: const ValueKey('batch-done-bar'),
                    onPressed: () => context.go('/'),
                    child: const Text('完成'),
                  )
                else
                  FilledButton.icon(
                    key: const ValueKey('batch-import-start'),
                    onPressed: canImport ? () => onImport() : null,
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(state.importing ? '导入中…' : '导入选中（$selected）'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
