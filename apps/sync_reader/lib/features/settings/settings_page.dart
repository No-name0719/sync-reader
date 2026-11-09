/// 设置页（docs/10 §4.7 / A15）：外观 + 阅读 + 存储 + 关于 四区单页。
///
/// - **外观**：主题风格三选（赭石/青瓷/墨绿，带配色预览）+ 外观模式
///   三选（浅色/深色/跟随系统）；经 `app_preferences.dart` 的 Notifier
///   即时生效（MaterialApp 重建）并同时落库（`app.accent` / `app.theme_mode`）。
/// - **阅读**：全局阅读默认值（字体/字号/行距/背景/音量键翻页），经既有
///   `ReaderSettingsRepository` 读写 reader_settings 表；改动在阅读器
///   下次打开时生效（本页不做热应用）。
/// - **存储**：books/covers/tmp 三目录占用统计 + 清理缓存（确认弹窗后
///   清空 tmp 目录内容）。
/// - **关于**：版本号（[appVersion]，与 pubspec 同步维护）、MIT、无账号
///   无遥测声明。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_preferences.dart';
import '../../app/providers.dart';
import '../../core/design_tokens.dart';
import '../../core/version.dart';
import '../../shared/format_utils.dart';
import '../reader/contract/reader_settings.dart';
import 'storage_usage.dart';

/// 本地存储占用统计（进入设置页时经 [StorageUsage.of] 异步计算）。
///
/// autoDispose：离开页面释放，重进重算；清理缓存后主动 invalidate 刷新。
final storageUsageProvider = FutureProvider.autoDispose<StorageUsage>((
  ref,
) async {
  final store = await ref.watch(bookFileStoreProvider.future);
  return StorageUsage.of(store);
});

/// 清理 tmp 缓存的动作（真实实现 = 清空 tmp 目录内容）。
///
/// 独立 provider 作为测试注入点：widget 测试运行在 fakeAsync 区，真实
/// 文件 IO 无法完成，测试替换为本假动作记录调用即可。
final tmpCacheCleanerProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final store = await ref.read(bookFileStoreProvider.future);
    await clearDirectoryContents(store.tmpDir);
  };
});

/// 设置页。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

final class _SettingsPageState extends ConsumerState<SettingsPage> {
  /// 全局阅读默认值（initState 异步从仓库读回；读回前先按出厂默认展示）。
  ReaderSettings _reader = ReaderSettings.defaults;

  @override
  void initState() {
    super.initState();
    _loadReaderDefaults();
  }

  Future<void> _loadReaderDefaults() async {
    try {
      final loaded = await ref.read(readerSettingsRepositoryProvider).load();
      if (mounted) setState(() => _reader = loaded);
    } catch (_) {
      // 库不可用：保持出厂默认展示，与阅读器侧「设置损坏回落默认」一致。
    }
  }

  /// 更新阅读默认值：UI 即时刷新 + 落库（下次打开阅读器生效）。
  void _updateReader(ReaderSettings next) {
    setState(() => _reader = next);
    ref.read(readerSettingsRepositoryProvider).save(next).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            // 原型 settings 屏 content-inner max-width: 820px。
            constraints: const BoxConstraints(maxWidth: 820),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.s5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildAppearance(context),
                  const SizedBox(height: AppSpacing.s4),
                  _buildReading(context),
                  const SizedBox(height: AppSpacing.s4),
                  _buildStorage(context),
                  const SizedBox(height: AppSpacing.s4),
                  _buildAbout(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 外观 ─────────────────────────────────────────────────────────────────

  Widget _buildAppearance(BuildContext context) {
    final accent = ref.watch(appAccentProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    return _SectionCard(
      title: '外观',
      badge: '立即生效',
      children: [
        Text('主题风格', style: _groupLabelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (index, option) in AppAccent.values.indexed) ...[
              if (index > 0) const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: _AccentOption(
                  accent: option,
                  selected: option == accent,
                  onTap: () =>
                      ref.read(appAccentProvider.notifier).setAccent(option),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        Text('外观模式', style: _groupLabelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        SegmentedButton<ThemeMode>(
          key: const ValueKey('app-settings-theme-mode'),
          segments: const [
            ButtonSegment(value: ThemeMode.light, label: Text('浅色')),
            ButtonSegment(value: ThemeMode.dark, label: Text('深色')),
            ButtonSegment(value: ThemeMode.system, label: Text('跟随系统')),
          ],
          selected: {themeMode},
          onSelectionChanged: (selection) => ref
              .read(appThemeModeProvider.notifier)
              .setThemeMode(selection.first),
        ),
      ],
    );
  }

  // ── 阅读 ─────────────────────────────────────────────────────────────────

  Widget _buildReading(BuildContext context) {
    return _SectionCard(
      title: '阅读',
      badge: '全局默认值',
      children: [
        _SettingRow(
          title: '默认字体',
          description: '衬线更接近纸质书；阅读器内可随时再改',
          bottom: SegmentedButton<String>(
            key: const ValueKey('app-settings-reader-font'),
            segments: const [
              ButtonSegment(value: _fontDefault, label: Text('跟随系统')),
              ButtonSegment(value: _fontSerif, label: Text('衬线')),
              ButtonSegment(value: _fontSans, label: Text('黑体')),
              ButtonSegment(value: _fontKai, label: Text('楷体')),
            ],
            selected: {_fontKeyOf(_reader.fontFamily)},
            onSelectionChanged: (selection) => _updateReader(
              _reader.copyWith(
                clearFontFamily: selection.first == _fontDefault,
                fontFamily: selection.first == _fontDefault
                    ? null
                    : selection.first,
              ),
            ),
          ),
        ),
        const Divider(height: AppSpacing.s6),
        _SettingRow(
          title: '默认字号',
          description: '正文字号（逻辑像素）',
          trailing: _valuePill(context, _reader.fontSize.toStringAsFixed(0)),
          bottom: Slider(
            key: const ValueKey('app-settings-font-size'),
            value: _reader.fontSize.clamp(12, 32),
            min: 12,
            max: 32,
            divisions: 20,
            label: _reader.fontSize.toStringAsFixed(0),
            onChanged: (value) =>
                _updateReader(_reader.copyWith(fontSize: value)),
          ),
        ),
        _SettingRow(
          title: '默认行距',
          description: '正文行距倍数',
          trailing: _valuePill(context, _reader.lineHeight.toStringAsFixed(1)),
          bottom: Slider(
            key: const ValueKey('app-settings-line-height'),
            value: _reader.lineHeight.clamp(1.2, 2.2),
            min: 1.2,
            max: 2.2,
            divisions: 10,
            label: _reader.lineHeight.toStringAsFixed(1),
            onChanged: (value) =>
                _updateReader(_reader.copyWith(lineHeight: value)),
          ),
        ),
        _SettingRow(
          title: '默认背景',
          description: '阅读器打开时的背景主题',
          // v1.2 B2：阅读主题 4→7 套（朴素颜色名）——七项超出分段按钮的
          // 单行容量（390 手机宽度溢出），改 Wrap 多行 chip。
          bottom: Wrap(
            key: const ValueKey('app-settings-reader-theme'),
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              for (final theme in ReaderTheme.values)
                ChoiceChip(
                  key: ValueKey('app-settings-reader-theme-${theme.name}'),
                  label: Text(theme.label),
                  selected: _reader.theme == theme,
                  onSelected: (_) =>
                      _updateReader(_reader.copyWith(theme: theme)),
                ),
            ],
          ),
        ),
        const Divider(height: AppSpacing.s6),
        _SettingRow(
          title: '音量键翻页',
          description: 'Android 专属；按下音量键翻页',
          trailing: Switch(
            key: const ValueKey('app-settings-volume-key'),
            value: _reader.volumeKeyPageTurn,
            onChanged: (value) =>
                _updateReader(_reader.copyWith(volumeKeyPageTurn: value)),
          ),
        ),
      ],
    );
  }

  // ── 存储 ─────────────────────────────────────────────────────────────────

  Widget _buildStorage(BuildContext context) {
    final stats = ref.watch(storageUsageProvider);
    return _SectionCard(
      title: '存储',
      children: [
        stats.when(
          loading: () => Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
            child: Text('正在统计本地占用…', style: _descStyle(context)),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
            child: Text('暂无法统计本地占用', style: _descStyle(context)),
          ),
          data: (usage) => Column(
            children: [
              _SettingRow(
                icon: Icons.description_outlined,
                title: '正文',
                description: 'books 目录 · ${humanizeBytes(usage.booksBytes)}',
              ),
              const SizedBox(height: AppSpacing.s3),
              _SettingRow(
                icon: Icons.image_outlined,
                title: '封面',
                description: 'covers 目录 · ${humanizeBytes(usage.coversBytes)}',
              ),
              const SizedBox(height: AppSpacing.s3),
              _SettingRow(
                icon: Icons.folder_outlined,
                title: '临时缓存',
                description: 'tmp 目录 · ${humanizeBytes(usage.tmpBytes)}',
              ),
            ],
          ),
        ),
        const Divider(height: AppSpacing.s6),
        _SettingRow(
          icon: Icons.cleaning_services_outlined,
          title: '清理缓存',
          description: '释放临时文件与下载缓存，不影响书库',
          trailing: OutlinedButton(
            key: const ValueKey('app-settings-clear-tmp'),
            onPressed: _confirmClearTmp,
            child: const Text('清理'),
          ),
        ),
      ],
    );
  }

  /// 清理缓存：确认弹窗 → 清空 tmp 目录内容 → 刷新统计 + 轻提示。
  Future<void> _confirmClearTmp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清理缓存'),
        content: const Text('将清空临时目录中的下载与上传暂存文件，不影响书库与阅读进度。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('app-settings-clear-tmp-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(tmpCacheCleanerProvider)();
    } catch (_) {
      // 清理失败不打扰用户：缓存不清不影响阅读。
    }
    if (!mounted) return;
    ref.invalidate(storageUsageProvider);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('缓存已清理')));
  }

  // ── 关于 ─────────────────────────────────────────────────────────────────

  Widget _buildAbout(BuildContext context) {
    return _SectionCard(
      title: '关于',
      children: [
        _SettingRow(
          title: 'SyncReader',
          description: '版本 $appVersion · MIT 开源许可 · 无账号 · 无遥测',
        ),
      ],
    );
  }

  // ── 小组件 ───────────────────────────────────────────────────────────────

  TextStyle _groupLabelStyle(BuildContext context) {
    final t = context.appTokens;
    return t.micro.copyWith(color: t.text3);
  }

  TextStyle _descStyle(BuildContext context) {
    final t = context.appTokens;
    return t.caption.copyWith(color: t.text2);
  }

  Widget _valuePill(BuildContext context, String text) {
    final t = context.appTokens;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s3,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: t.surface3,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        text,
        style: t.micro.copyWith(fontWeight: FontWeight.w600, color: t.text2),
      ),
    );
  }
}

/// 阅读字体选项的控件键（fontFamily 可空，控件统一用非空键）。
const _fontDefault = '';

/// 衬线（宋体）：取设计令牌衬线栈首选（Q2）。
const _fontSerif = AppFonts.serif;

/// 黑体：取设计令牌黑体栈。
const _fontSans = AppFonts.sans;

/// 楷体：取设计令牌楷体栈（Q2 第三档）。
const _fontKai = AppFonts.kai;

/// fontFamily → 控件键（未知字体按跟随系统处理，向后兼容旧值）。
String _fontKeyOf(String? fontFamily) => switch (fontFamily) {
  null || _fontDefault => _fontDefault,
  _fontSerif => _fontSerif,
  _fontSans => _fontSans,
  _fontKai => _fontKai,
  _ => _fontDefault,
};

/// 分区卡片：`t.surface` + `AppRadius.lg` + 1px `t.border` 描边，
/// 头部为标题（+ 可选徽标 pill），主体为各行内容。
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, this.badge, required this.children});

  final String title;
  final String? badge;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s4,
              AppSpacing.s4,
              0,
            ),
            child: Row(
              children: [
                Expanded(child: Text(title, style: t.h3)),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: t.surface3,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                    ),
                    child: Text(
                      badge!,
                      style: t.micro.copyWith(
                        fontWeight: FontWeight.w600,
                        color: t.text2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 设置行：可选图标 + 标题/说明 + 尾部控件 + 可选底部控件（滑块/分段）。
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    this.icon,
    required this.title,
    this.description,
    this.trailing,
    this.bottom,
  });

  final IconData? icon;
  final String title;
  final String? description;
  final Widget? trailing;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: t.text3),
          const SizedBox(width: AppSpacing.s3),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: t.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (trailing != null) ...[trailing!],
                ],
              ),
              if (description != null) ...[
                const SizedBox(height: 2),
                Text(description!, style: t.caption.copyWith(color: t.text2)),
              ],
              if (bottom != null) ...[
                const SizedBox(height: AppSpacing.s2),
                bottom!,
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 品牌风格选择卡（原型 .accent-opt）：三色预览条 + 名称 + 描述。
class _AccentOption extends StatelessWidget {
  const _AccentOption({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    // 预览色固定取该 accent 的浅色版三色（原型预览即浅色值，与当前明暗无关）。
    final preview = AppDesignTokens.light(accent);
    final description = switch (accent) {
      AppAccent.terracotta => '纸墨暖调 · 默认',
      AppAccent.teal => '清冷沉静',
      AppAccent.ink => '线装书气质',
    };
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          color: selected ? t.brandSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? t.brand : t.border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 30,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(color: t.border),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: preview.brand,
                      child: SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: preview.brandSoft,
                      child: SizedBox.expand(),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: preview.brandHover,
                      child: SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              accent.label,
              style: t.sm.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 1),
            Text(
              description,
              style: t.micro.copyWith(fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }
}
