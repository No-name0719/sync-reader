/// 设置页（docs/10 §4.7 / A15）：外观 + 阅读 + 存储 + 关于 四区单页。
///
/// - **外观**：主题风格三选（赭石/青瓷/墨绿，带配色预览）+ 外观模式
///   三选（浅色/深色/跟随系统）；经 `app_preferences.dart` 的 Notifier
///   即时生效（MaterialApp 重建）并同时落库（`app.accent` / `app.theme_mode`）。
/// - **阅读**：全局阅读默认值（字体/字号/行距/背景/翻页方式/音量键翻页），经既有
///   `ReaderSettingsRepository` 读写 reader_settings 表；改动在阅读器
///   下次打开时生效（本页不做热应用）。**翻页方式**在本页也可切换——
///   移动端的 Aa 面板是底部弹层，该项埋在面板下半部分不易发现
///   （v1.3.6，用户反馈「移动端无法切换滚动和分页模式」）；
///   v1.3.7 起只有「滚动（上下）/ 分页（左右）」两种方式（原「翻页模式 +
///   翻页动画」两控件已合并，见 Aa 面板）。
/// - **存储**：books/covers/tmp 三目录占用统计 + 清理缓存（确认弹窗后
///   清空 tmp 目录内容）。
/// - **关于**：版本号（[appVersion]，与 pubspec 同步维护）、MIT、无账号
///   无遥测声明。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/app_preferences.dart';
import '../../app/providers.dart';
import '../../core/design_tokens.dart';
import '../../core/version.dart';
import '../../shared/format_utils.dart';
import '../../shared/icon_alignment.dart';
import '../../shared/segment_row.dart';
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

  /// 仓库变更订阅：阅读器内的 Aa 面板改了设置时，本页实时跟随
  /// （v1.3.6：此前本页只在进入时读一次，改动后重进会显示旧值）。
  StreamSubscription<ReaderSettings>? _readerSub;

  @override
  void initState() {
    super.initState();
    _loadReaderDefaults();
    _readerSub = ref.read(readerSettingsRepositoryProvider).changes.listen((
      next,
    ) {
      if (mounted && next != _reader) setState(() => _reader = next);
    });
  }

  @override
  void dispose() {
    _readerSub?.cancel();
    super.dispose();
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
        _buildAccentOptions(context, accent),
        const SizedBox(height: AppSpacing.s4),
        Text('外观模式', style: _groupLabelStyle(context)),
        const SizedBox(height: AppSpacing.s2),
        AppSegmentRow<ThemeMode>(
          key: const ValueKey('app-settings-theme-mode'),
          options: const [
            (ThemeMode.light, '浅色'),
            (ThemeMode.dark, '深色'),
            (ThemeMode.system, '跟随系统'),
          ],
          selected: themeMode,
          onChanged: (value) =>
              ref.read(appThemeModeProvider.notifier).setThemeMode(value),
        ),
      ],
    );
  }

  /// 主题风格三选卡：按原型 `.accent-opts` 的 `auto-fit minmax(140px, 1fr)`
  /// 排布——**放不下就换行成两列**，而不是把三列硬挤在一行里。
  ///
  /// 此前用 `Row` + `Expanded` 硬分三列：360px 宽的手机上每列只剩 ~98px，
  /// 描述「纸墨暖调 · 默认」放不下 → 被迫折成两行（「纸墨暖调 · 默 / 认」，
  /// 用户实测「移动端分行，很难看」）。原型在同样宽度下是**两列**。
  Widget _buildAccentOptions(BuildContext context, AppAccent accent) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 原型：minmax(140px, 1fr) → 每列至少 140px，放不下就少放一列。
        const minCardWidth = 140.0;
        const gap = AppSpacing.s3;
        final fits = ((constraints.maxWidth + gap) / (minCardWidth + gap))
            .floor();
        final columns = math.max(1, math.min(AppAccent.values.length, fits));
        final cardWidth =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final option in AppAccent.values)
              SizedBox(
                width: cardWidth,
                child: _AccentOption(
                  accent: option,
                  selected: option == accent,
                  onTap: () =>
                      ref.read(appAccentProvider.notifier).setAccent(option),
                ),
              ),
          ],
        );
      },
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
          description: '阅读器内可随时再改',
          bottom: AppSegmentRow<String>(
            key: const ValueKey('app-settings-reader-font'),
            options: const [
              (_fontDefault, '跟随系统'),
              (_fontSerif, '衬线'),
              (_fontSans, '黑体'),
              (_fontKai, '楷体'),
            ],
            selected: _fontKeyOf(_reader.fontFamily),
            onChanged: (value) => _updateReader(
              _reader.copyWith(
                clearFontFamily: value == _fontDefault,
                fontFamily: value == _fontDefault ? null : value,
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
          title: '默认翻页方式',
          bottom: AppSegmentRow<ReaderPageMode>(
            key: const ValueKey('app-settings-reader-page-mode'),
            options: const [
              (ReaderPageMode.page, '分页'),
              (ReaderPageMode.scroll, '滚动'),
            ],
            selected: _reader.pageMode,
            onChanged: (value) => _updateReader(
              _reader.copyWith(
                pageMode: value,
                // 分页方向固定「左右」（上下滑动翻页选项已下线）。
                pageTurnAxis: ReaderPageTurnAxis.horizontal,
              ),
            ),
          ),
        ),
        const Divider(height: AppSpacing.s6),
        _SettingRow(
          title: '音量键翻页',
          description: 'Android 专属',
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
        content: const Text('将清空下载与上传暂存文件，不影响书库与阅读进度。'),
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
    final titleStyle = t.body.copyWith(fontWeight: FontWeight.w600);
    // 说明/底部控件相对**标题**左对齐（图标在标题行内 → 补同样的缩进）。
    final gutter = icon != null ? 18 + AppSpacing.s3 : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          // 图标与标题**在同一个 Row**里 → 天然对齐。图标按**标题行盒**
          // （body 14×22 = 22）居中：此前图标盒只有 18 高且顶对齐 → 图标
          // 中心比文字中心高 2px，看着「图标和字没对齐」（用户实测：存储区
          // 四行最明显；「清理缓存」行还因尾部按钮把标题压低，整体差 13px）。
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (icon != null) ...[
              IconLineSlot(
                lineHeight: textLineHeight(titleStyle),
                child: Icon(icon, size: 18, color: t.text3),
              ),
              const SizedBox(width: AppSpacing.s3),
            ],
            Expanded(
              child: Text(
                title,
                style: titleStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null) ...[trailing!],
          ],
        ),
        if (description != null) ...[
          const SizedBox(height: 2),
          Padding(
            padding: EdgeInsets.only(left: gutter),
            child: Text(
              description!,
              style: t.caption.copyWith(color: t.text2),
            ),
          ),
        ],
        if (bottom != null) ...[
          const SizedBox(height: AppSpacing.s2),
          Padding(
            padding: EdgeInsets.only(left: gutter),
            child: bottom!,
          ),
        ],
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
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.sm.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 1),
            Text(
              description,
              // 描述单行（放不下就截断，不折行）——卡片高度因此恒定，
              // 三张卡的预览条/名称/描述始终齐平。
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.micro.copyWith(fontWeight: FontWeight.w400),
            ),
          ],
        ),
      ),
    );
  }
}
