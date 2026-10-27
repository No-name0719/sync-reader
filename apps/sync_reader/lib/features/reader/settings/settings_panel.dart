/// 阅读设置面板（FR-206）：字号/行距/页边距/主题/字体/翻页模式/txt 编码。
///
/// 由阅读页经 `showModalBottomSheet` 底部拖出；所有变更即时
/// `repository.save` 持久化（排版设置仅本地保存、不同步，docs/07 记录），
/// 阅读页监听 `repository.changes` 后经渲染器 `applySettings` 热应用。
/// 面板初始值消费 `repository.current`，并在 open 后与持久化值对齐一次。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../contract/reader_settings.dart';
import '../formats/txt/txt_theme.dart';

/// 面板内字体选项的展示键（fontFamily 为可空字符串，控件统一用非空键）。
const _fontDefault = 'default';
const _fontSerif = 'serif';
const _fontMonospace = 'monospace';

/// fontFamily → 控件键（null/未知字体 → 默认）。
String _fontKeyOf(String? fontFamily) => switch (fontFamily) {
  _fontSerif => _fontSerif,
  _fontMonospace => _fontMonospace,
  _ => _fontDefault,
};

/// 控件键 → fontFamily（默认 → null = 平台默认字体）。
String? _fontValueOf(String key) => switch (key) {
  _fontSerif => _fontSerif,
  _fontMonospace => _fontMonospace,
  _ => null,
};

/// 阅读设置面板。
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
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('阅读设置', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              _buildFontSize(context),
              _buildLineHeight(context),
              _buildPageMargin(context),
              const SizedBox(height: 8),
              _buildTheme(context),
              const SizedBox(height: 8),
              _buildFontFamily(context),
              const SizedBox(height: 8),
              _buildPageMode(context),
              const SizedBox(height: 8),
              _buildEncoding(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _labelRow(BuildContext context, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label),
        Text(value, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildFontSize(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labelRow(context, '字号', _settings.fontSize.toStringAsFixed(0)),
        Slider(
          key: const ValueKey('settings-font-size'),
          value: _settings.fontSize.clamp(12, 32),
          min: 12,
          max: 32,
          divisions: 20,
          label: _settings.fontSize.toStringAsFixed(0),
          onChanged: (value) => _update(_settings.copyWith(fontSize: value)),
        ),
      ],
    );
  }

  Widget _buildLineHeight(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labelRow(context, '行距', _settings.lineHeight.toStringAsFixed(1)),
        Slider(
          key: const ValueKey('settings-line-height'),
          value: _settings.lineHeight.clamp(1.2, 2.2),
          min: 1.2,
          max: 2.2,
          divisions: 10,
          label: _settings.lineHeight.toStringAsFixed(1),
          onChanged: (value) => _update(_settings.copyWith(lineHeight: value)),
        ),
      ],
    );
  }

  Widget _buildPageMargin(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _labelRow(context, '页边距', _settings.pageMargin.toStringAsFixed(0)),
        Slider(
          key: const ValueKey('settings-page-margin'),
          value: _settings.pageMargin.clamp(8, 40),
          min: 8,
          max: 40,
          divisions: 32,
          label: _settings.pageMargin.toStringAsFixed(0),
          onChanged: (value) => _update(_settings.copyWith(pageMargin: value)),
        ),
      ],
    );
  }

  /// 主题三选（浅色/深色/纸张），色块预览复用 txt 主题配色。
  Widget _buildTheme(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('主题', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final theme in ReaderTheme.values) ...[
              if (theme != ReaderTheme.light) const SizedBox(width: 8),
              Expanded(
                child: _themeOption(context, theme, switch (theme) {
                  ReaderTheme.light => '浅色',
                  ReaderTheme.dark => '深色',
                  ReaderTheme.paper => '纸张',
                }),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _themeOption(BuildContext context, ReaderTheme theme, String label) {
    final colors = TxtThemeColors.of(theme);
    final selected = _settings.theme == theme;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('settings-theme-${theme.name}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _update(_settings.copyWith(theme: theme)),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Container(
              height: 36,
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: scheme.outlineVariant),
              ),
              alignment: Alignment.center,
              child: Text(
                '字',
                style: TextStyle(color: colors.foreground, fontSize: 16),
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Widget _buildFontFamily(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('字体', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: _fontDefault, label: Text('默认')),
              ButtonSegment(value: _fontSerif, label: Text('衬线')),
              ButtonSegment(value: _fontMonospace, label: Text('等宽')),
            ],
            selected: {_fontKeyOf(_settings.fontFamily)},
            onSelectionChanged: (selection) => _update(
              _settings.copyWith(fontFamily: _fontValueOf(selection.first)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPageMode(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('翻页模式', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ReaderPageMode>(
            segments: const [
              ButtonSegment(
                value: ReaderPageMode.scroll,
                icon: Icon(Icons.swap_vert),
                label: Text('滚动'),
              ),
              ButtonSegment(
                value: ReaderPageMode.page,
                icon: Icon(Icons.auto_stories),
                label: Text('分页'),
              ),
            ],
            selected: {_settings.pageMode},
            onSelectionChanged: (selection) =>
                _update(_settings.copyWith(pageMode: selection.first)),
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
        const SizedBox(height: 8),
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
        const SizedBox(height: 4),
        Text('编码切换仅对 txt 生效', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
