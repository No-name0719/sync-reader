/// 阅读设置面板（v1.2 B4：入口为齿轮图标；docs/10 A9/A14/A23 重做）：
/// 实时预览框（跟随全部设置项）+ 实时对比度读数（WCAG 2.1 实算）+
/// 字号/行距/页边距 + 段距（整行空行，B4）+ 首行缩进开关（B4）+
/// 字体三选（衬线·黑体·楷体，带字体预览）+ 7 种背景（B2）+
/// 夜间亮度（B3，仅夜间系背景显示）+ 翻页模式（Q9）+
/// 翻页动画（B5，仅分页模式显示）+ txt 编码，另含 Android 专属的
/// 音量键翻页开关（FR-209）。
///
/// 形态由宿主（阅读页）决定：桌面（>860）右侧抽屉、移动（≤860）底部弹层
/// （docs/10 §4.4），本 widget 只承载内容，两种形态共用。
///
/// 所有变更即时 `repository.save` 持久化（排版设置仅本地保存、不同步，
/// docs/07 记录），阅读页监听 `repository.changes` 后经渲染器
/// `applySettings` 热应用。面板初始值消费 `repository.current`，
/// 并在 open 后与持久化值对齐一次。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design_tokens.dart';
import '../contract/reader_settings.dart';

/// 预览框示例文字（与原型 ui_prototype 一致）。
const String _previewSample =
    '天光将明未明时，窗纸上映出一层极淡的灰。案上的残灯早已冷透，'
    '灯芯结着一小截白花。';

/// 阅读设置面板（内容体；抽屉/弹层形态由宿主包装）。
class ReaderSettingsPanel extends ConsumerStatefulWidget {
  const ReaderSettingsPanel({super.key});

  @override
  ConsumerState<ReaderSettingsPanel> createState() =>
      _ReaderSettingsPanelState();
}

class _ReaderSettingsPanelState extends ConsumerState<ReaderSettingsPanel> {
  late ReaderSettings _settings;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(readerSettingsRepositoryProvider);
    _settings = repo.current;
    // 面板通常由阅读页打开（仓库已 load）；兜底与持久化值对齐一次。
    repo.load().then((loaded) {
      if (mounted && loaded != _settings) {
        setState(() => _settings = loaded);
      }
    });
  }

  /// 更新设置：UI 即时刷新 + 持久化（阅读页监听 changes 热应用）。
  void _update(ReaderSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    ref.read(readerSettingsRepositoryProvider).save(next);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _settings.theme.palette;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: AppSpacing.s4),
            _buildPreview(),
            const SizedBox(height: AppSpacing.s2),
            _buildContrastNote(context, palette),
            const SizedBox(height: AppSpacing.s5),
            _buildFontSize(context),
            _buildLineHeight(context),
            _buildPageMargin(context),
            const SizedBox(height: AppSpacing.s5),
            _buildParagraphGap(context),
            _buildFirstLineIndent(context),
            const SizedBox(height: AppSpacing.s5),
            _buildFontFamily(context),
            const SizedBox(height: AppSpacing.s5),
            _buildTheme(context),
            if (_settings.theme.isNight) ...[
              const SizedBox(height: AppSpacing.s5),
              _buildNightBrightness(context),
            ],
            const SizedBox(height: AppSpacing.s5),
            _buildPageMode(context),
            // 翻页动画仅分页模式有意义（原型行为）。
            if (_settings.pageMode == ReaderPageMode.page) ...[
              const SizedBox(height: AppSpacing.s5),
              _buildPageTurnAxis(context),
            ],
            const SizedBox(height: AppSpacing.s5),
            _buildEncoding(context),
            // 音量键翻页（FR-209）为 Android 专属能力，其他平台不显示该行。
            if (Platform.isAndroid) ...[
              const SizedBox(height: AppSpacing.s5),
              _buildVolumeKeyPageTurn(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text('阅读设置', style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton(
          key: const ValueKey('aa-close'),
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  /// 实时预览框（A9/I4）：随字号/行距/段距/缩进/字体/背景即时变化，
  /// 段首 2em 全角空格缩进随开关切换（与三渲染器同款等价实现）。
  Widget _buildPreview() {
    final palette = _settings.theme.palette;
    final font = resolveReaderFont(_settings.fontFamily);
    return Container(
      key: const ValueKey('aa-preview'),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 110),
      padding: const EdgeInsets.all(AppSpacing.s4),
      alignment: Alignment.topLeft,
      decoration: BoxDecoration(
        color: palette.bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: palette.rule),
      ),
      child: Text(
        '${_settings.firstLineIndent ? kReaderParagraphIndent : ''}$_previewSample',
        textAlign: TextAlign.justify,
        style: TextStyle(
          fontSize: _settings.fontSize,
          height: _settings.lineHeight,
          color: palette.fg,
          fontFamily: font.family,
          fontFamilyFallback: font.fallback,
        ),
      ),
    );
  }

  /// 实时对比度读数（B2/B4）：按当前主题色值 WCAG 2.1 实算，非写死数字。
  Widget _buildContrastNote(BuildContext context, ReaderPalette palette) {
    final fg = palette.fgContrast;
    final muted = palette.mutedContrast;
    return Text(
      '正文对比度 ${fg.toStringAsFixed(1)}:1 · ${wcagContrastLevel(fg)}'
      '　|　次级文字 ${muted.toStringAsFixed(1)}:1',
      key: const ValueKey('aa-contrast-note'),
      style: Theme.of(context).textTheme.bodySmall,
    );
  }

  Widget _sliderRow(
    BuildContext context, {
    required String label,
    required String valueText,
    required ValueKey<String> sliderKey,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Text(valueText, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          key: sliderKey,
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: valueText,
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 字号滑杆（A14 核查结论：min=12 / max=32 / 步进 1 → divisions 应为
  /// `(32 - 12) / 1 = 20`，与现状一致——docs/10 I5 所记「divisions: 20 与
  /// min12/max32 不匹配」与代码不符，实际步长本就是 1，无需修正，仅在此
  /// 注明核查依据。出厂字号改 19（docs/10 §4.4 正文 19px），19 = 12 + 7×1
  /// 落在网格上；已持久化的用户设置不受影响（fromJson 原样读回）。
  Widget _buildFontSize(BuildContext context) {
    return _sliderRow(
      context,
      label: '字号',
      valueText: _settings.fontSize.toStringAsFixed(0),
      sliderKey: const ValueKey('settings-font-size'),
      value: _settings.fontSize,
      min: 12,
      max: 32,
      divisions: 20, // (32-12)/步进1 = 20，见上方核查结论
      onChanged: (value) => _update(_settings.copyWith(fontSize: value)),
    );
  }

  /// 行距滑杆：min=1.2 / max=2.2 / 步进 0.05 → divisions = 20（v1.0 为
  /// 步进 0.1 的 10 格；出厂行距改 1.95（docs/10 §4.4），0.05 步进才能
  /// 落在网格上，1.95 = 1.2 + 15×0.05）。
  Widget _buildLineHeight(BuildContext context) {
    return _sliderRow(
      context,
      label: '行距',
      valueText: _settings.lineHeight.toStringAsFixed(2),
      sliderKey: const ValueKey('settings-line-height'),
      value: _settings.lineHeight,
      min: 1.2,
      max: 2.2,
      divisions: 20, // (2.2-1.2)/步进0.05 = 20
      onChanged: (value) => _update(_settings.copyWith(lineHeight: value)),
    );
  }

  /// 页边距滑杆：min=8 / max=40 / 步进 1 → divisions = (40-8)/1 = 32，
  /// 与现状一致（自洽，无需修正）。
  Widget _buildPageMargin(BuildContext context) {
    return _sliderRow(
      context,
      label: '页边距',
      valueText: _settings.pageMargin.toStringAsFixed(0),
      sliderKey: const ValueKey('settings-page-margin'),
      value: _settings.pageMargin,
      min: 8,
      max: 40,
      divisions: 32, // (40-8)/步进1 = 32，自洽
      onChanged: (value) => _update(_settings.copyWith(pageMargin: value)),
    );
  }

  /// 夜间亮度滑杆（B3）：80%–130%、步进 5，只在夜间系背景显示；
  /// 作用整屏（背景与正文一起变），80% 下限保证正文对比度仍达 AAA
  /// （对比度门测试锁定）。
  Widget _buildNightBrightness(BuildContext context) {
    final percent = (_settings.nightBrightness * 100).round();
    return _sliderRow(
      context,
      label: '夜间亮度',
      valueText: '$percent%',
      sliderKey: const ValueKey('settings-night-brightness'),
      value: _settings.nightBrightness,
      min: 0.8,
      max: 1.3,
      divisions: 10, // (1.3-0.8)/步进0.05 = 10
      onChanged: (value) =>
          _update(_settings.copyWith(nightBrightness: value)),
    );
  }

  /// 段距三选（B4）：紧 / 空一行 / 空两行（以整行为单位，不破坏行网格）。
  Widget _buildParagraphGap(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('段距', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ReaderParagraphGap>(
            key: const ValueKey('settings-paragraph-gap'),
            segments: const [
              ButtonSegment(value: ReaderParagraphGap.tight, label: Text('紧')),
              ButtonSegment(
                value: ReaderParagraphGap.oneLine,
                label: Text('空一行'),
              ),
              ButtonSegment(
                value: ReaderParagraphGap.twoLines,
                label: Text('空两行'),
              ),
            ],
            selected: {_settings.paragraphGap},
            onSelectionChanged: (selection) =>
                _update(_settings.copyWith(paragraphGap: selection.first)),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '以整行为单位：每页行数恒定，页底留白不随内容长短跳动',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 首行缩进开关（B4）：缩进 2em（两个全角空格，显示层等价实现）↔ 不缩进。
  Widget _buildFirstLineIndent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.s5),
        Text('首行缩进', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<bool>(
            key: const ValueKey('settings-first-line-indent'),
            segments: const [
              ButtonSegment(value: true, label: Text('缩进 2em')),
              ButtonSegment(value: false, label: Text('不缩进')),
            ],
            selected: {_settings.firstLineIndent},
            onSelectionChanged: (selection) =>
                _update(_settings.copyWith(firstLineIndent: selection.first)),
          ),
        ),
      ],
    );
  }

  /// 字体三选（Q2：衬线为默认；每项用该字体渲染预览字样，A9）。
  Widget _buildFontFamily(BuildContext context) {
    final selectedFamily = resolveReaderFont(_settings.fontFamily).family;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('字体', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        ...[
          (AppFonts.serif, '宋体 · 阅读', 'Noto Serif SC'),
          (AppFonts.sans, '黑体 · 清晰', '系统黑体'),
          (AppFonts.kai, '楷体 · 温润', 'KaiTi'),
        ].map(
          (option) => _fontOption(
            context,
            family: option.$1,
            sample: option.$2,
            note: option.$3,
            selected: selectedFamily == option.$1,
          ),
        ),
      ],
    );
  }

  Widget _fontOption(
    BuildContext context, {
    required String family,
    required String sample,
    required String note,
    required bool selected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s2),
      child: InkWell(
        key: ValueKey('settings-font-$family'),
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _update(_settings.copyWith(fontFamily: family)),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s3,
            vertical: AppSpacing.s2,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
            color: selected ? scheme.primaryContainer : Colors.transparent,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  sample,
                  style: TextStyle(
                    fontSize: 17,
                    // 预览字样必须用该字体本身渲染（A9）。
                    fontFamily: family,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Text(note, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  /// 背景七选（B2）：色块选择器，色值取 design_tokens 权威 ReaderPalette，
  /// 每片用该主题的 bg/fg 渲染「字」样与朴素颜色名。
  Widget _buildTheme(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('阅读背景', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        GridView.count(
          key: const ValueKey('settings-themes'),
          crossAxisCount: 4,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.s2,
          crossAxisSpacing: AppSpacing.s2,
          childAspectRatio: 1.15,
          children: [
            for (final theme in ReaderTheme.values) _themeSwatch(context, theme),
          ],
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '阅读背景与应用深浅色相互独立：应用是浅色时也可切夜间背景',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _themeSwatch(BuildContext context, ReaderTheme theme) {
    final palette = theme.palette;
    final selected = _settings.theme == theme;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('settings-theme-${theme.name}'),
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: () => _update(_settings.copyWith(theme: theme)),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: palette.bg,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                alignment: Alignment.center,
                child: Text(
                  '字',
                  style: TextStyle(color: palette.fg, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              theme.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// 翻页模式（Q9：出厂默认分页；原型顺序 分页·滚动）。
  ///
  /// 说明文字如实标注各格式支持现状（B 要求「不要假装支持」）：分页对
  /// txt 为整行精确分页；epub 为连续排版按屏吸附；md 暂以滚动呈现；
  /// pdf 的「页」由文件自带。
  Widget _buildPageMode(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('翻页模式', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ReaderPageMode>(
            segments: const [
              ButtonSegment(
                value: ReaderPageMode.page,
                icon: Icon(Icons.auto_stories),
                label: Text('分页'),
              ),
              ButtonSegment(
                value: ReaderPageMode.scroll,
                icon: Icon(Icons.swap_vert),
                label: Text('滚动'),
              ),
            ],
            selected: {_settings.pageMode},
            onSelectionChanged: (selection) =>
                _update(_settings.copyWith(pageMode: selection.first)),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '分页：txt 整行精确分页；epub 连续排版按屏吸附；md 暂按滚动呈现；pdf 按文件自带页呈现',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// 翻页动画（B5）：上下滑动（默认，正文像滚动一样纵向推移）/ 左右翻页。
  /// 仅分页模式显示；两种动画共用同一排版与翻页路径（ReaderController）。
  Widget _buildPageTurnAxis(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('翻页动画', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ReaderPageTurnAxis>(
            key: const ValueKey('settings-page-turn-axis'),
            segments: const [
              ButtonSegment(
                value: ReaderPageTurnAxis.vertical,
                icon: Icon(Icons.swipe_up),
                label: Text('上下滑动'),
              ),
              ButtonSegment(
                value: ReaderPageTurnAxis.horizontal,
                icon: Icon(Icons.swipe),
                label: Text('左右翻页'),
              ),
            ],
            selected: {_settings.pageTurnAxis},
            onSelectionChanged: (selection) =>
                _update(_settings.copyWith(pageTurnAxis: selection.first)),
          ),
        ),
      ],
    );
  }

  Widget _buildEncoding(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('txt 编码', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ReaderTextEncoding>(
            segments: const [
              ButtonSegment(value: ReaderTextEncoding.auto, label: Text('自动')),
              ButtonSegment(
                value: ReaderTextEncoding.utf8,
                label: Text('UTF-8'),
              ),
              ButtonSegment(value: ReaderTextEncoding.gbk, label: Text('GBK')),
            ],
            selected: {_settings.txtEncodingOverride},
            onSelectionChanged: (selection) => _update(
              _settings.copyWith(txtEncodingOverride: selection.first),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text('编码切换仅对 txt 生效', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  /// 音量键翻页开关（FR-209，Android 专属）：开启后阅读页启用平台通道
  /// 拦截音量键（音量上键 = 上一页，音量下键 = 下一页）。
  Widget _buildVolumeKeyPageTurn(BuildContext context) {
    return SwitchListTile(
      key: const ValueKey('settings-volume-key-page-turn'),
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: const Text('音量键翻页'),
      subtitle: const Text('按下音量键翻页，不再调节音量'),
      value: _settings.volumeKeyPageTurn,
      onChanged: (value) =>
          _update(_settings.copyWith(volumeKeyPageTurn: value)),
    );
  }
}
