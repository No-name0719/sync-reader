/// 阅读设置面板（v1.2 B4：入口为齿轮图标；docs/10 A9/A14/A23 重做）：
/// 实时预览框（跟随全部设置项）+ 实时对比度读数（WCAG 2.1 实算）+
/// 字号/行距/页边距 + 段距（整行空行，B4）+ 首行缩进开关（B4）+
/// 字体三选（衬线·黑体·楷体，带字体预览）+ 7 种背景（B2）+
/// 夜间亮度（B3，仅夜间系背景显示）+ **翻页方式**（v1.3.7：滚动（上下）/
/// 分页（左右）两种，原「翻页模式 + 翻页动画」两控件合并）+ txt 编码，
/// 另含 Android 专属的音量键翻页开关（FR-209）。
///
/// 形态由宿主（阅读页）决定：桌面（>860）右侧抽屉、移动（≤860）底部弹层
/// （docs/10 §4.4），本 widget 只承载内容，两种形态共用。
///
/// 视觉尺度对齐原型 `ui_prototype/reader.css` 的 `.rd-ty-*`（单元 2）：
/// - 面板内边距 16；头部标题 14px/w600；
/// - 分组标题 12px/w600/muted（`.rd-ty-group > label`）；
/// - 右侧数值 12px/前景色/等宽数字（`.rd-val`）；
/// - 说明小字 11px/行高 1.6/muted（`.rd-hint-text`）；对比度读数 11px
///   （`.rd-ty-note`）；
/// - 分段控件自绘（`_SegmentRow`，仿 `.rd-seg`）：surfaceContainerHighest
///   底 + 圆角 8 + 内边距 3 + 子项间距 2；子项 12px muted，选中项白底
///   + 600 字重 + 轻阴影，**不带 ✓ 勾选图标**；
/// - 滑块统一细轨道（3px）+ 12px 圆点手柄（accent 色不变）。
///
/// 所有变更即时 `repository.save` 持久化（排版设置仅本地保存、不同步，
/// docs/07 记录），阅读页监听 `repository.changes` 后经渲染器
/// `applySettings` 热应用。面板初始值消费 `repository.current`，
/// 并在 open 后与持久化值对齐一次；面板打开期间跟随仓库变更流
/// （v1.3.6：别处改过设置后，面板不再显示旧值）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/design_tokens.dart';
import '../contract/reader_settings.dart';
import '../reader_indent.dart';

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

  /// 仓库变更订阅：面板打开期间若别处改了设置（如设置页），面板实时跟随。
  StreamSubscription<ReaderSettings>? _sub;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(readerSettingsRepositoryProvider);
    _settings = repo.current;
    // 面板通常由阅读页打开（仓库已 load）；此处对齐同一前置。
    repo.load().then((loaded) {
      if (mounted && loaded != _settings) {
        setState(() => _settings = loaded);
      }
    });
    _sub = repo.changes.listen((next) {
      if (mounted && next != _settings) setState(() => _settings = next);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 更新设置：UI 即时刷新 + 持久化（阅读页监听 changes 热应用）。
  void _update(ReaderSettings next) {
    if (next == _settings) return;
    setState(() => _settings = next);
    ref.read(readerSettingsRepositoryProvider).save(next);
  }

  /// 恢复默认（E5-1）：排版相关项回到 [ReaderSettings.defaults]，
  /// 阅读主题 / 翻页模式 / 翻页动画 / 编码 / 音量键开关**原样保留**
  /// （原型 `data-act="reset"` 同款语义：只重置排版）。
  void _resetToDefaults() {
    final d = ReaderSettings.defaults;
    _update(
      _settings.copyWith(
        fontSize: d.fontSize,
        lineHeight: d.lineHeight,
        pageMargin: d.pageMargin,
        paragraphGap: d.paragraphGap,
        firstLineIndent: d.firstLineIndent,
        // 字体：null = 衬线（copyWith 需显式 clear 才能置空）。
        clearFontFamily: true,
        nightBrightness: d.nightBrightness,
      ),
    );
  }

  // —— 排版尺度（原型 `.rd-ty-*`）——

  /// 分组标题：12px / w600 / muted（原型 `--text-2`）。
  TextStyle _labelStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// 右侧数值：12px / 前景色 / 等宽数字（原型 `.rd-val`）。
  TextStyle _valueStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!.copyWith(
      fontSize: 12,
      color: theme.colorScheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// 说明小字：11px / 行高 1.6 / muted（原型 `.rd-hint-text`）。
  TextStyle _hintStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.bodySmall!.copyWith(
      fontSize: 11,
      height: 1.6,
      color: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// 头部标题：14px / w600（原型 `.rd-drawer-head b`）。
  TextStyle _headerTitleStyle(BuildContext context) {
    final theme = Theme.of(context);
    return theme.textTheme.titleMedium!.copyWith(fontSize: 14);
  }

  /// 滑块统一形态（原型原生 range：细轨道 + 小圆点手柄）。
  /// 颜色沿用主题 accent（品牌色），只统一轨道/手柄形状。
  SliderThemeData _sliderTheme(BuildContext context) {
    return SliderTheme.of(context).copyWith(
      trackHeight: 3,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SliderTheme(
        data: _sliderTheme(context),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context),
              const SizedBox(height: AppSpacing.s4),
              _buildPreview(),
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
              _buildTurnMode(context),
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
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text('阅读设置', style: _headerTitleStyle(context)),
        ),
        // 恢复默认（E5-1）：只重置排版项，保留主题/翻页模式/动画/编码等。
        IconButton(
          key: const ValueKey('aa-reset'),
          icon: const Icon(Icons.adjust),
          tooltip: '恢复默认',
          onPressed: _resetToDefaults,
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
      child: Text.rich(
        // 段首缩进用行内占位符（正文同一机制）：空白字符会被两端对齐吞掉，
        // 预览里就看不到 2em 缩进了。
        TextSpan(
          style: TextStyle(
            fontSize: _settings.fontSize,
            height: _settings.lineHeight,
            color: palette.fg,
            fontFamily: font.family,
            fontFamilyFallback: font.fallback,
          ),
          children: [
            if (_settings.firstLineIndent)
              readerIndentSpan(_settings.fontSize),
            TextSpan(text: _previewSample),
          ],
        ),
        textAlign: TextAlign.justify,
      ),
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
            Text(label, style: _labelStyle(context)),
            Text(valueText, style: _valueStyle(context)),
          ],
        ),
        // 标签与手柄之间留 8px 空隙，避免粘连（原型 label 下缘即滑块）。
        const SizedBox(height: AppSpacing.s2),
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
  /// 注明核查依据。出厂字号为 16（单元 1 起正文 16px），16 = 12 + 4×1
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

  /// 行距滑杆：min=1.2 / max=2.4 / 步进 0.05 → divisions = 24（对齐原型
  /// `#rdLh` 的 min 1.2 / max 2.4 / step 0.05）；出厂行距 1.95 =
  /// 1.2 + 15×0.05 落在网格上。
  Widget _buildLineHeight(BuildContext context) {
    return _sliderRow(
      context,
      label: '行距',
      valueText: _settings.lineHeight.toStringAsFixed(2),
      sliderKey: const ValueKey('settings-line-height'),
      value: _settings.lineHeight,
      min: 1.2,
      max: 2.4,
      divisions: 24, // (2.4-1.2)/步进0.05 = 24
      onChanged: (value) => _update(_settings.copyWith(lineHeight: value)),
    );
  }

  /// 页边距滑杆：min=8 / max=72 / 步进 4 → divisions = 16（对齐原型
  /// `#rdPad`）；出厂页边距 24 = 8 + 4×4 落在网格上。
  Widget _buildPageMargin(BuildContext context) {
    return _sliderRow(
      context,
      label: '页边距',
      valueText: _settings.pageMargin.toStringAsFixed(0),
      sliderKey: const ValueKey('settings-page-margin'),
      value: _settings.pageMargin,
      min: 8,
      max: 72,
      divisions: 16, // (72-8)/步进4 = 16
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

  /// 段距三选（B4）：紧 / 疏·空一行 / 松·空两行（以整行为单位，不破坏行网格）。
  Widget _buildParagraphGap(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('段距', style: _labelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        _SegmentRow<ReaderParagraphGap>(
          key: const ValueKey('settings-paragraph-gap'),
          options: const [
            (ReaderParagraphGap.tight, '紧'),
            (ReaderParagraphGap.oneLine, '空一行'),
            (ReaderParagraphGap.twoLines, '空两行'),
          ],
          selected: _settings.paragraphGap,
          onChanged: (value) =>
              _update(_settings.copyWith(paragraphGap: value)),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '以整行为单位',
          style: _hintStyle(context),
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
        Text('首行缩进', style: _labelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        _SegmentRow<bool>(
          key: const ValueKey('settings-first-line-indent'),
          options: const [(true, '缩进 2em'), (false, '不缩进')],
          selected: _settings.firstLineIndent,
          onChanged: (value) =>
              _update(_settings.copyWith(firstLineIndent: value)),
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
        Text('字体', style: _labelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        ...[
          (AppFonts.serif, '宋体', 'Noto Serif SC'),
          (AppFonts.sans, '黑体', '系统黑体'),
          (AppFonts.kai, '楷体', 'KaiTi'),
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
              Text(note, style: _hintStyle(context)),
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
        Text('阅读背景', style: _labelStyle(context)),
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
          '与应用深浅色相互独立',
          style: _hintStyle(context),
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
              style: _hintStyle(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 翻页方式（v1.3.7：原「翻页模式 + 翻页动画」两个控件合并为一个）。
  ///
  /// 只有两种方式：**滚动** 与 **分页**。翻页**方向**不再作为选项——
  /// 电脑端翻页有两条与方向无关的路（点正文左右两侧热区、方向键；滚轮
  /// 已在 v1.3.7 从分页模式移除），方向只影响「按住拖拽」这一个次要手势；
  /// 而方向本身还随格式而异（txt 手机左右滑 / 电脑上下拖；epub 始终上下
  /// 按屏吸附），写进选项名反而会误导 → 方向只在说明文字里逐格式标注。
  ///
  /// 说明文字如实标注各格式支持现状（B 要求「不要假装支持」）：滚动为
  /// 上下滑动连续阅读；分页对 txt 为整行精确分页（方向按设备形态自动选）；
  /// epub 为连续排版按屏吸附（纵向滑动）；md 暂以滚动呈现；pdf 的「页」
  /// 由文件自带。
  Widget _buildTurnMode(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('翻页方式', style: _labelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        _SegmentRow<ReaderPageMode>(
          key: const ValueKey('settings-page-mode'),
          options: const [
            (ReaderPageMode.page, '分页'),
            (ReaderPageMode.scroll, '滚动'),
          ],
          selected: _settings.pageMode,
          onChanged: (value) => _update(
            _settings.copyWith(
              pageMode: value,
              // 分页方向已不是用户选项（按设备形态自动选），这里写横轴只是
              // 让持久化值保持一致（旧键只增不删）。
              pageTurnAxis: ReaderPageTurnAxis.horizontal,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s1),
        Text(
          '滚动 = 上下滑动连续阅读；分页 = 一页一页翻'
          '（epub 按屏吸附；md 暂按滚动；pdf 按文件自带页）',
          style: _hintStyle(context),
        ),
      ],
    );
  }

  Widget _buildEncoding(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('txt 编码', style: _labelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        _SegmentRow<ReaderTextEncoding>(
          key: const ValueKey('settings-encoding'),
          options: const [
            (ReaderTextEncoding.auto, '自动'),
            (ReaderTextEncoding.utf8, 'UTF-8'),
            (ReaderTextEncoding.gbk, 'GBK'),
          ],
          selected: _settings.txtEncodingOverride,
          onChanged: (value) =>
              _update(_settings.copyWith(txtEncodingOverride: value)),
        ),
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
      title: Text('音量键翻页', style: _labelStyle(context)),
      subtitle: Text('不再调节音量', style: _hintStyle(context)),
      value: _settings.volumeKeyPageTurn,
      onChanged: (value) =>
          _update(_settings.copyWith(volumeKeyPageTurn: value)),
    );
  }
}

/// 面板内私有分段控件（单元 2 自绘，替代 Material [SegmentedButton]）。
///
/// 形态对齐原型 `ui_prototype/reader.css` 的 `.rd-seg`：
/// - 外层容器：surfaceContainerHighest 底、圆角 8、内边距 3、子项间距 2；
/// - 子项：Expanded、垂直居中、padding 6/8、字号 12、muted 文字色；
/// - 选中项：surface 底 + 前景色 600 字重 + 轻阴影，**不带 ✓ 勾选图标**。
///
/// 语义：以 [Semantics] 的 `button` + `selected` 暴露选中态（读屏可用），
/// [InkWell] 保留点击/悬停/键盘（Enter/Space）操作能力。
class _SegmentRow<T> extends StatelessWidget {
  const _SegmentRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  /// 选项列表：每项为 `(值, 文案)`。
  final List<(T, String)> options;

  /// 当前选中值。
  final T selected;

  /// 选中项变更回调。
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(child: _buildItem(context, options[i])),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, (T, String) option) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = option.$1 == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      child: Container(
        decoration: isSelected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                // 选中项：白底 + 很轻的阴影（原型 `.rd-seg button.is-on`）。
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              )
            : null,        child: Material(
          color: isSelected ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onChanged(option.$1),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                option.$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
