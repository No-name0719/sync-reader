/// 设计令牌（docs/10 §3 设计系统；唯一事实源 = `ui_prototype/styles.css` 第 1-233 行）。
///
/// 本文件把原型 CSS 变量逐字翻译成 Dart 常量 + 一个 [ThemeExtension]，
/// 供全局通过 `Theme.of(context).extension<AppDesignTokens>()` 取用：
///
/// ```dart
/// final t = Theme.of(context).extension<AppDesignTokens>()!;
/// Text('书名', style: t.h2);
/// Container(
///   padding: const EdgeInsets.all(AppSpacing.s4),
///   decoration: BoxDecoration(
///     color: t.surface,
///     borderRadius: BorderRadius.circular(AppRadius.lg),
///     border: Border.all(color: t.border),
///   ),
/// );
/// ```
///
/// 约定：
/// - 颜色值与原型 CSS 变量一一对应，不做近似；
/// - 不打包中文字体（体积门 NFR-04），UI 走平台默认字体，阅读正文走系统衬线栈；
/// - 阅读主题独立于应用主题，本文件提供 7 套静态配色（v1.2 B2，
///   见 [AppReaderTheme]）+ WCAG 对比度工具（面板读数与测试共用）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

// ===========================================================================
// 一、品牌风格（accent）
// ===========================================================================

/// 品牌风格：三选一，默认赭石（Q3）。
///
/// 对应原型 `[data-accent="terracotta|teal|ink"]`。
enum AppAccent {
  /// 赭石（默认）：纸墨暖调，贴「读书」这件事。
  terracotta('赭石'),

  /// 青瓷：清冷沉静（原 teal 基因，去饱和）。
  teal('青瓷'),

  /// 墨绿：线装书气质。
  ink('墨绿');

  const AppAccent(this.label);

  /// 中文显示名（设置页「外观」三选一用）。
  final String label;

  /// 按名称解析：接受英文枚举名（大小写不敏感）或中文名。
  ///
  /// 解析失败一律回落到默认的 [AppAccent.terracotta]，
  /// 避免持久化数据被外部改坏后整个应用起不来。
  static AppAccent fromName(String name) {
    final key = name.trim().toLowerCase();
    for (final accent in AppAccent.values) {
      if (accent.name.toLowerCase() == key || accent.label == name.trim()) {
        return accent;
      }
    }
    return AppAccent.terracotta;
  }
}

// ===========================================================================
// 二、基础尺度（间距 / 圆角 / 布局 / 字体栈）
// ===========================================================================

/// 间距阶梯：4px 基准（原型 `--s1` … `--s12`）。
abstract final class AppSpacing {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;
}

/// 圆角阶梯（原型 `--r-xs` … `--r-full`）。
abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double full = 999;
}

/// 布局常量（原型 `--rail-w` / `--topbar-h` / `--content-max` / `--reader-max`）。
abstract final class AppLayout {
  /// 桌面端左侧导航栏宽度（Q1）。
  static const double railWidth = 232;

  /// 窄窗（<1180px）收成的图标栏宽度（Q1）。
  static const double railNarrowWidth = 68;

  /// 顶栏高度。
  static const double topBarHeight = 60;

  /// 主内容最大宽度（居中）。
  static const double contentMaxWidth = 1240;

  /// 阅读正文列宽。
  static const double readerMaxWidth = 720;

  /// 书库网格卡宽下限（Q6：154px 起，7 列 @1440）。
  static const double cardMinWidth = 154;

  /// 书库列表模式行高。
  static const double listRowHeight = 78;
}

/// 字体栈常量（不打包字体文件，走系统字体；Q4）。
abstract final class AppFonts {
  /// UI 字体族（拉丁部分）：**按运行平台解析**（docs/10 §3.2）。
  ///
  /// 此前硬写 'Roboto'（Android 原生族），在 Windows 上该字体并不存在 →
  /// 引擎回退到平台默认字体（Segoe UI），中文再落到 DirectWrite 的系统回退链，
  /// 得到的是一支与拉丁不同源、且不认 `w600` 字重的怪字体：中英混排像两种字体，
  /// 标题字重也被抹平（见 docs/10 §9.20）。
  ///
  /// 现在按平台取「该平台真正装着的拉丁字体」，CJK 由 [uiFallback] 显式接上，
  /// 不再依赖引擎的系统回退（那支脸各机器不同）。
  ///
  /// 字阶**必须**显式带上字体族：Material 的 `englishLike` typography 本身就
  /// 是 'Roboto'，而 `textTheme` 槽位是从 typography 合并而来（带字体族）；
  /// 直接使用裸字阶样式（如 `SwitchListTile` 标题、`AppBarTheme.titleTextStyle`）
  /// 就会丢掉它，导致同一页面上部分文字落到别的字体，与全站不一致。
  static String get ui => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'Segoe UI',
    TargetPlatform.macOS || TargetPlatform.iOS => 'Helvetica Neue',
    TargetPlatform.android => 'Roboto',
    _ => 'Noto Sans',
  };

  /// UI 字体的 CJK 回退栈：主字体没有的汉字按此顺序取。
  ///
  /// 各平台取**该平台通用的中文字体**（Windows 微软雅黑、macOS/iOS 苹方、
  /// Android/Linux 思源黑体），保证「拉丁 + 汉字」是同一套观感，且字重可用
  /// （雅黑/苹方/思源都有真正的 Bold 面，不会被合成）。
  static List<String> get uiFallback => switch (defaultTargetPlatform) {
    TargetPlatform.windows => const <String>[
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans SC',
    ],
    TargetPlatform.macOS ||
    TargetPlatform.iOS => const <String>['PingFang SC', 'Heiti SC'],
    TargetPlatform.android => const <String>[
      'Noto Sans SC',
      'Noto Sans CJK SC',
    ],
    _ => const <String>['Noto Sans CJK SC', 'WenQuanYi Zen Hei', 'DejaVu Sans'],
  };

  /// 阅读正文衬线栈首选：思源宋体 / Noto Serif SC。
  static const String serif = 'Noto Serif SC';

  /// 阅读正文黑体备选。
  static const String sans = 'Noto Sans SC';

  /// 阅读正文楷体备选（Q2）。
  static const String kai = 'KaiTi';

  /// 等宽字体（诊断日志、哈希等场景备查）。
  static const String mono = 'Cascadia Code';
}

// ===========================================================================
// 三、字阶
// ===========================================================================

/// 字阶规格：字号 + 行高 + 字重。
///
/// [height] 是 CSS 里的「行高像素」，Flutter 的 `TextStyle.height` 是
/// 「行高倍数」，所以换算时用 [heightRatio]。
@immutable
class AppTextStyleSpec {
  const AppTextStyleSpec({
    required this.name,
    required this.fontSize,
    required this.height,
    required this.weight,
  });

  /// 字阶名（display / h1 / h2 / h3 / body / sm / caption / micro）。
  final String name;

  /// 字号（px）。
  final double fontSize;

  /// 行高（px）。
  final double height;

  /// 字重（Flutter `FontWeight`）。
  final FontWeight weight;

  /// 行高倍数（= 行高像素 / 字号），对应 `TextStyle.height`。
  double get heightRatio => height / fontSize;

  @override
  String toString() => 'AppTextStyleSpec($name, $fontSize/$height, $weight)';
}

/// 八档字阶（原型 §3.2 字阶表）。
///
/// 字重映射：680→w700、650→w700、620→w600、600→w600、400→w400。
abstract final class AppTextScale {
  /// 30/38 · 680 —— 书名、页面主标题。
  static const AppTextStyleSpec display = AppTextStyleSpec(
    name: 'display',
    fontSize: 30,
    height: 38,
    weight: FontWeight.w700,
  );

  /// 22/30 · 620 —— 章节标题。
  static const AppTextStyleSpec h1 = AppTextStyleSpec(
    name: 'h1',
    fontSize: 22,
    height: 30,
    weight: FontWeight.w600,
  );

  /// 18/26 · 650 —— 页面标题、卡片标题。
  static const AppTextStyleSpec h2 = AppTextStyleSpec(
    name: 'h2',
    fontSize: 18,
    height: 26,
    weight: FontWeight.w700,
  );

  /// 15/22 · 620 —— 分组标题。
  static const AppTextStyleSpec h3 = AppTextStyleSpec(
    name: 'h3',
    fontSize: 15,
    height: 22,
    weight: FontWeight.w600,
  );

  /// 14/22 · 400 —— 正文、列表主行。
  static const AppTextStyleSpec body = AppTextStyleSpec(
    name: 'body',
    fontSize: 14,
    height: 22,
    weight: FontWeight.w400,
  );

  /// 13/20 · 400 —— 次级正文。
  static const AppTextStyleSpec sm = AppTextStyleSpec(
    name: 'sm',
    fontSize: 13,
    height: 20,
    weight: FontWeight.w400,
  );

  /// 12/18 · 400 —— 辅助说明。
  static const AppTextStyleSpec caption = AppTextStyleSpec(
    name: 'caption',
    fontSize: 12,
    height: 18,
    weight: FontWeight.w400,
  );

  /// 11/16 · 600 —— 标签、角标（旧版 9px/10px 角标全部上调至此）。
  static const AppTextStyleSpec micro = AppTextStyleSpec(
    name: 'micro',
    fontSize: 11,
    height: 16,
    weight: FontWeight.w600,
  );

  /// 全部字阶（供自检与设置页预览使用）。
  static const List<AppTextStyleSpec> all = <AppTextStyleSpec>[
    display,
    h1,
    h2,
    h3,
    body,
    sm,
    caption,
    micro,
  ];
}

// ===========================================================================
// 四、阅读主题（独立于应用主题）
// ===========================================================================

/// 阅读主题配色（v1.2 B2：7 套，命名用朴素颜色描述）。
///
/// 色值权威源；对比度门（正文 ≥7:1 AAA、次级 ≥4.5:1）由
/// `test/core/design_tokens_test.dart` 按 WCAG 2.1 实算锁定，
/// 夜间系主题另锁定「80% 最低亮度下仍达标」（B3）。
@immutable
class ReaderPalette {
  const ReaderPalette({
    required this.bg,
    required this.fg,
    required this.muted,
    required this.rule,
    required this.pageShadow,
  });

  /// 背景色。
  final Color bg;

  /// 正文色。
  final Color fg;

  /// 弱化文字色（页码、章节提示）。
  final Color muted;

  /// 分隔线颜色。
  final Color rule;

  /// 页面投影颜色（分页模式下纸张阴影）。
  final Color pageShadow;

  /// 正文对背景的 WCAG 对比度。
  double get fgContrast => wcagContrastRatio(fg, bg);

  /// 次级文字对背景的 WCAG 对比度。
  double get mutedContrast => wcagContrastRatio(muted, bg);

  /// 按比例插值（主题过渡用）。
  ReaderPalette lerp(ReaderPalette other, double t) => ReaderPalette(
    bg: Color.lerp(bg, other.bg, t)!,
    fg: Color.lerp(fg, other.fg, t)!,
    muted: Color.lerp(muted, other.muted, t)!,
    rule: Color.lerp(rule, other.rule, t)!,
    pageShadow: Color.lerp(pageShadow, other.pageShadow, t)!,
  );
}

/// 七套阅读主题（v1.2 B2：白色/米黄/浅绿/浅灰蓝/深灰/深棕/纯黑）。
///
/// 命名约定（B2）：**枚举名保持稳定（持久化兼容），中文 label 用朴素颜色
/// 描述**。v1.1 的 paper/beige/green/dark 枚举名原样保留，仅 label 由
/// 「纸白/护眼/夜间」改为「白色/浅绿/深灰」；slate/dusk/ink 为新增。
enum AppReaderTheme {
  /// 白色（默认；v1.1 label「纸白」）。
  paper('白色'),

  /// 米黄（旧版「纸张」的升级）。
  beige('米黄'),

  /// 浅绿（v1.1 label「护眼」）。
  green('浅绿'),

  /// 浅灰蓝（v1.2 新增）。
  slate('浅灰蓝'),

  /// 深灰（夜间系；v1.1 label「夜间」）。
  dark('深灰'),

  /// 深棕（夜间系，暖调；v1.2 新增）。
  dusk('深棕'),

  /// 纯黑（夜间系，OLED 友好；v1.2 新增）。
  ink('纯黑');

  const AppReaderTheme(this.label);

  /// 中文显示名（排版面板/设置页用；朴素颜色描述，B2）。
  final String label;

  /// 是否夜间系（B3：夜间亮度滑块只在夜间系背景出现）。
  bool get isNight => switch (this) {
    AppReaderTheme.dark || AppReaderTheme.dusk || AppReaderTheme.ink => true,
    _ => false,
  };

  /// 该主题的配色。
  ReaderPalette get palette => switch (this) {
    AppReaderTheme.paper => const ReaderPalette(
      bg: Color(0xFFFFFFFF),
      fg: Color(0xFF26251F),
      muted: Color(0xFF6F6C64),
      rule: Color(0xFFECEAE4),
      pageShadow: Color(0x241C1A16),
    ),
    AppReaderTheme.beige => const ReaderPalette(
      bg: Color(0xFFF6EFE0),
      fg: Color(0xFF40382B),
      muted: Color(0xFF6B6152),
      rule: Color(0xFFE3D9C2),
      pageShadow: Color(0x29504228),
    ),
    AppReaderTheme.green => const ReaderPalette(
      bg: Color(0xFFE5EEE2),
      fg: Color(0xFF2B3529),
      muted: Color(0xFF556354),
      rule: Color(0xFFD2DDCD),
      pageShadow: Color(0x24283C28),
    ),
    AppReaderTheme.slate => const ReaderPalette(
      bg: Color(0xFFE9EEF4),
      fg: Color(0xFF262E3A),
      muted: Color(0xFF56616F),
      rule: Color(0xFFD5DCE5),
      pageShadow: Color(0x241E2836),
    ),
    AppReaderTheme.dark => const ReaderPalette(
      bg: Color(0xFF14151A),
      fg: Color(0xFFC8CACD),
      muted: Color(0xFF9AA0A8),
      rule: Color(0xFF26282E),
      pageShadow: Color(0x80000000),
    ),
    AppReaderTheme.dusk => const ReaderPalette(
      bg: Color(0xFF1E1913),
      fg: Color(0xFFD8CFC0),
      muted: Color(0xFFB0A492),
      rule: Color(0xFF332C22),
      pageShadow: Color(0x80000000),
    ),
    AppReaderTheme.ink => const ReaderPalette(
      bg: Color(0xFF0B0B0D),
      fg: Color(0xFFDADADD),
      muted: Color(0xFF9C9CA4),
      rule: Color(0xFF222226),
      pageShadow: Color(0x80000000),
    ),
  };
}

// ===========================================================================
// 四-b、WCAG 2.1 对比度（v1.2 B2/B3：面板实时读数与测试共用）
// ===========================================================================

/// sRGB 通道值（0-255）→ 线性光（WCAG 2.1 相对亮度公式的分通道变换）。
double _srgbChannelToLinear(int value) {
  final c = value / 255;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// 颜色的 WCAG 2.1 相对亮度（L = 0.2126R + 0.7152G + 0.0722B，线性光）。
double colorRelativeLuminance(Color color) =>
    0.2126 * _srgbChannelToLinear(((color.r * 255.0).round())) +
    0.7152 * _srgbChannelToLinear(((color.g * 255.0).round())) +
    0.0722 * _srgbChannelToLinear(((color.b * 255.0).round()));

/// 两色 WCAG 2.1 对比度（(L亮+0.05)/(L暗+0.05)，≥7 AAA、≥4.5 AA）。
double wcagContrastRatio(Color a, Color b) {
  final la = colorRelativeLuminance(a);
  final lb = colorRelativeLuminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 对比度等级文案（WCAG 2.1，正文场景）。
String wcagContrastLevel(double ratio) {
  if (ratio >= 7) return 'AAA';
  if (ratio >= 4.5) return 'AA';
  if (ratio >= 3) return 'AA（仅大字）';
  return '不合格';
}

/// 亮度系数下的缩放色（B3 夜间亮度）。
///
/// 与渲染端 `ColorFiltered` 亮度矩阵同口径：sRGB 各通道线性缩放并钳制，
/// 作用于整屏（背景与正文一起变暗/变亮），不是只调文字。
Color scaleColorBrightness(Color color, double factor) => Color.fromARGB(
  ((color.a * 255.0).round()),
  (((color.r * 255.0).round()) * factor).round().clamp(0, 255),
  (((color.g * 255.0).round()) * factor).round().clamp(0, 255),
  (((color.b * 255.0).round()) * factor).round().clamp(0, 255),
);

// ===========================================================================
// 五、主题扩展
// ===========================================================================

/// 设计令牌主题扩展：所有颜色 / 字阶 / 阴影的全局取用入口。
///
/// 用法：`Theme.of(context).extension<AppDesignTokens>()!`。
@immutable
class AppDesignTokens extends ThemeExtension<AppDesignTokens> {
  const AppDesignTokens({
    required this.brightness,
    required this.accent,
    required this.bg,
    required this.surface,
    required this.surface2,
    required this.surface3,
    required this.surfaceInset,
    required this.border,
    required this.borderStrong,
    required this.text,
    required this.text2,
    required this.text3,
    required this.textInv,
    required this.success,
    required this.successSoft,
    required this.warn,
    required this.warnSoft,
    required this.danger,
    required this.dangerSoft,
    required this.info,
    required this.infoSoft,
    required this.brand,
    required this.brandHover,
    required this.brandSoft,
    required this.brandSoft2,
    required this.brandText,
    required this.scrim,
    required this.sh1,
    required this.sh2,
    required this.sh3,
    required this.brandFocus,
    required this.readerPalette,
  });

  /// 浅色主题令牌（中性色 + 语义色固定，品牌色随 accent 变）。
  factory AppDesignTokens.light(AppAccent accent) {
    final brand = _brandOf(accent, dark: false);
    return AppDesignTokens(
      brightness: Brightness.light,
      accent: accent,
      bg: const Color(0xFFF6F5F1),
      surface: const Color(0xFFFFFFFF),
      surface2: const Color(0xFFFAF9F6),
      surface3: const Color(0xFFEFEEE9),
      surfaceInset: const Color(0xFFF1F0EB),
      border: const Color(0xFFE4E2DB),
      borderStrong: const Color(0xFFD1CEC4),
      text: const Color(0xFF1D1C1A),
      text2: const Color(0xFF6A6862),
      text3: const Color(0xFF98958C),
      textInv: const Color(0xFFFFFFFF),
      success: const Color(0xFF1F7A4D),
      successSoft: const Color(0xFFE0F2E8),
      warn: const Color(0xFFA95B06),
      warnSoft: const Color(0xFFFBEEDA),
      danger: const Color(0xFFB42318),
      dangerSoft: const Color(0xFFFCE9E6),
      info: const Color(0xFF2563EB),
      infoSoft: const Color(0xFFE4EDFD),
      brand: brand.brand,
      brandHover: brand.brandHover,
      brandSoft: brand.brandSoft,
      brandSoft2: brand.brandSoft2,
      brandText: brand.brandText,
      scrim: const Color(0x6B1C1A16),
      sh1: const <BoxShadow>[
        BoxShadow(
          color: Color(0x0F1C1A16),
          blurRadius: 2,
          offset: Offset(0, 1),
        ),
        BoxShadow(
          color: Color(0x0A1C1A16),
          blurRadius: 1,
          offset: Offset(0, 1),
        ),
      ],
      sh2: const <BoxShadow>[
        BoxShadow(
          color: Color(0x121C1A16),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
        BoxShadow(
          color: Color(0x0D1C1A16),
          blurRadius: 2,
          offset: Offset(0, 1),
        ),
      ],
      sh3: const <BoxShadow>[
        BoxShadow(
          color: Color(0x211C1A16),
          blurRadius: 36,
          offset: Offset(0, 14),
        ),
        BoxShadow(
          color: Color(0x121C1A16),
          blurRadius: 10,
          offset: Offset(0, 3),
        ),
      ],
      brandFocus: <BoxShadow>[
        BoxShadow(
          color: brand.brand.withValues(alpha: 0.26),
          blurRadius: 0,
          spreadRadius: 3,
        ),
      ],
      readerPalette: AppReaderTheme.paper.palette,
    );
  }

  /// 深色主题令牌（中性色 + 语义色固定，品牌色随 accent 变）。
  factory AppDesignTokens.dark(AppAccent accent) {
    final brand = _brandOf(accent, dark: true);
    return AppDesignTokens(
      brightness: Brightness.dark,
      accent: accent,
      bg: const Color(0xFF121317),
      surface: const Color(0xFF1A1C21),
      surface2: const Color(0xFF212429),
      surface3: const Color(0xFF2A2E35),
      surfaceInset: const Color(0xFF16181C),
      border: const Color(0xFF2C3038),
      borderStrong: const Color(0xFF3A3F49),
      text: const Color(0xFFE9E7E2),
      text2: const Color(0xFF9EA2AB),
      text3: const Color(0xFF6F747E),
      textInv: const Color(0xFF121317),
      success: const Color(0xFF4EC27F),
      successSoft: const Color(0xFF12301F),
      warn: const Color(0xFFE0A34A),
      warnSoft: const Color(0xFF33260F),
      danger: const Color(0xFFF28B82),
      dangerSoft: const Color(0xFF3A1A17),
      info: const Color(0xFF7AA7F8),
      infoSoft: const Color(0xFF17233F),
      brand: brand.brand,
      brandHover: brand.brandHover,
      brandSoft: brand.brandSoft,
      brandSoft2: brand.brandSoft2,
      brandText: brand.brandText,
      scrim: const Color(0x99000000),
      sh1: const <BoxShadow>[
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 2,
          offset: Offset(0, 1),
        ),
      ],
      sh2: const <BoxShadow>[
        BoxShadow(
          color: Color(0x73000000),
          blurRadius: 10,
          offset: Offset(0, 2),
        ),
      ],
      sh3: const <BoxShadow>[
        BoxShadow(
          color: Color(0x99000000),
          blurRadius: 40,
          offset: Offset(0, 16),
        ),
        BoxShadow(
          color: Color(0x66000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
      brandFocus: <BoxShadow>[
        BoxShadow(
          color: brand.brand.withValues(alpha: 0.32),
          blurRadius: 0,
          spreadRadius: 3,
        ),
      ],
      readerPalette: AppReaderTheme.paper.palette,
    );
  }

  // —— 中性色（表面 / 描边 / 文字）——

  /// 应用底色（`--bg`）。
  final Color bg;

  /// 卡片表面（`--surface`）。
  final Color surface;

  /// 次级填充（`--surface-2`）。
  final Color surface2;

  /// 三级填充（`--surface-3`，hover 底色）。
  final Color surface3;

  /// 内嵌区填充（`--surface-inset`）。
  final Color surfaceInset;

  /// 1px 描边（`--border`）。
  final Color border;

  /// 强调描边（`--border-strong`）。
  final Color borderStrong;

  /// 主文字（`--text`）。
  final Color text;

  /// 次要文字（`--text-2`）。
  final Color text2;

  /// 三级文字（`--text-3`）。
  final Color text3;

  /// 反色文字（`--text-inv`）。
  final Color textInv;

  // —— 语义色 ——

  /// 成功色。
  final Color success;

  /// 成功色浅底。
  final Color successSoft;

  /// 警告色。
  final Color warn;

  /// 警告色浅底。
  final Color warnSoft;

  /// 危险色。
  final Color danger;

  /// 危险色浅底。
  final Color dangerSoft;

  /// 信息色。
  final Color info;

  /// 信息色浅底。
  final Color infoSoft;

  // —— 品牌色（随 accent 变）——

  /// 品牌主色（`--brand`）。
  final Color brand;

  /// 品牌主色 hover / pressed（`--brand-hover`）。
  final Color brandHover;

  /// 品牌浅底（选中态底色，`--brand-soft`）。
  final Color brandSoft;

  /// 品牌浅底 hover（`--brand-soft-2`）。
  final Color brandSoft2;

  /// 品牌浅底上的可读文字色（`--brand-text`）。
  final Color brandText;

  /// 遮罩色（`--scrim`）。
  final Color scrim;

  // —— 阴影 ——

  /// 一级阴影（`--sh-1`）。
  final List<BoxShadow> sh1;

  /// 二级阴影（`--sh-2`）。
  final List<BoxShadow> sh2;

  /// 三级阴影（`--sh-3`，浮层 / 弹窗）。
  final List<BoxShadow> sh3;

  /// 品牌聚焦环（`--sh-focus`）。
  final List<BoxShadow> brandFocus;

  // —— 阅读主题 ——

  /// 当前阅读主题配色（默认纸白；与 App 明暗无关）。
  final ReaderPalette readerPalette;

  /// 阅读背景色。
  Color get readerBg => readerPalette.bg;

  /// 阅读正文色。
  Color get readerFg => readerPalette.fg;

  /// 阅读弱化文字色。
  Color get readerMuted => readerPalette.muted;

  /// 阅读分隔线色。
  Color get readerRule => readerPalette.rule;

  /// 阅读页面投影色。
  Color get readerPageShadow => readerPalette.pageShadow;

  // —— 其它元信息 ——

  /// 明暗。
  final Brightness brightness;

  /// 当前品牌风格。
  final AppAccent accent;

  /// 是否深色主题。
  bool get isDark => brightness == Brightness.dark;

  // —— 字阶（八档）——

  /// 30/38 —— 书名、页面主标题。
  TextStyle get display => _style(AppTextScale.display, text);

  /// 22/30 —— 章节标题。
  TextStyle get h1 => _style(AppTextScale.h1, text);

  /// 18/26 —— 页面标题、卡片标题。
  TextStyle get h2 => _style(AppTextScale.h2, text);

  /// 15/22 —— 分组标题。
  TextStyle get h3 => _style(AppTextScale.h3, text);

  /// 14/22 —— 正文、列表主行。
  TextStyle get body => _style(AppTextScale.body, text);

  /// 13/20 —— 次级正文。
  TextStyle get sm => _style(AppTextScale.sm, text);

  /// 12/18 —— 辅助说明。
  TextStyle get caption => _style(AppTextScale.caption, text2);

  /// 11/16 —— 标签、角标。
  TextStyle get micro => _style(AppTextScale.micro, text2);

  /// 三级文字样式（`--text-3`）。
  TextStyle get tertiary => _style(AppTextScale.caption, text3);

  TextStyle _style(AppTextStyleSpec spec, Color color) => TextStyle(
    fontFamily: AppFonts.ui,
    fontFamilyFallback: AppFonts.uiFallback,
    fontSize: spec.fontSize,
    height: spec.heightRatio,
    fontWeight: spec.weight,
    color: color,
  );

  // —— 字体栈 ——

  /// 阅读正文衬线字体（Q2 默认）。
  String get readerFontFamily => AppFonts.serif;

  /// 阅读正文黑体备选。
  String get readerSansFontFamily => AppFonts.sans;

  /// 阅读正文楷体备选。
  String get readerKaiFontFamily => AppFonts.kai;

  // —— ThemeExtension ——

  @override
  AppDesignTokens copyWith({
    Brightness? brightness,
    AppAccent? accent,
    Color? bg,
    Color? surface,
    Color? surface2,
    Color? surface3,
    Color? surfaceInset,
    Color? border,
    Color? borderStrong,
    Color? text,
    Color? text2,
    Color? text3,
    Color? textInv,
    Color? success,
    Color? successSoft,
    Color? warn,
    Color? warnSoft,
    Color? danger,
    Color? dangerSoft,
    Color? info,
    Color? infoSoft,
    Color? brand,
    Color? brandHover,
    Color? brandSoft,
    Color? brandSoft2,
    Color? brandText,
    Color? scrim,
    List<BoxShadow>? sh1,
    List<BoxShadow>? sh2,
    List<BoxShadow>? sh3,
    List<BoxShadow>? brandFocus,
    ReaderPalette? readerPalette,
  }) {
    return AppDesignTokens(
      brightness: brightness ?? this.brightness,
      accent: accent ?? this.accent,
      bg: bg ?? this.bg,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      surface3: surface3 ?? this.surface3,
      surfaceInset: surfaceInset ?? this.surfaceInset,
      border: border ?? this.border,
      borderStrong: borderStrong ?? this.borderStrong,
      text: text ?? this.text,
      text2: text2 ?? this.text2,
      text3: text3 ?? this.text3,
      textInv: textInv ?? this.textInv,
      success: success ?? this.success,
      successSoft: successSoft ?? this.successSoft,
      warn: warn ?? this.warn,
      warnSoft: warnSoft ?? this.warnSoft,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      info: info ?? this.info,
      infoSoft: infoSoft ?? this.infoSoft,
      brand: brand ?? this.brand,
      brandHover: brandHover ?? this.brandHover,
      brandSoft: brandSoft ?? this.brandSoft,
      brandSoft2: brandSoft2 ?? this.brandSoft2,
      brandText: brandText ?? this.brandText,
      scrim: scrim ?? this.scrim,
      sh1: sh1 ?? this.sh1,
      sh2: sh2 ?? this.sh2,
      sh3: sh3 ?? this.sh3,
      brandFocus: brandFocus ?? this.brandFocus,
      readerPalette: readerPalette ?? this.readerPalette,
    );
  }

  @override
  AppDesignTokens lerp(AppDesignTokens? other, double t) {
    if (other == null) return this;
    return AppDesignTokens(
      brightness: t < 0.5 ? brightness : other.brightness,
      accent: t < 0.5 ? accent : other.accent,
      bg: Color.lerp(bg, other.bg, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surface2: Color.lerp(surface2, other.surface2, t)!,
      surface3: Color.lerp(surface3, other.surface3, t)!,
      surfaceInset: Color.lerp(surfaceInset, other.surfaceInset, t)!,
      border: Color.lerp(border, other.border, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      text: Color.lerp(text, other.text, t)!,
      text2: Color.lerp(text2, other.text2, t)!,
      text3: Color.lerp(text3, other.text3, t)!,
      textInv: Color.lerp(textInv, other.textInv, t)!,
      success: Color.lerp(success, other.success, t)!,
      successSoft: Color.lerp(successSoft, other.successSoft, t)!,
      warn: Color.lerp(warn, other.warn, t)!,
      warnSoft: Color.lerp(warnSoft, other.warnSoft, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerSoft: Color.lerp(dangerSoft, other.dangerSoft, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoSoft: Color.lerp(infoSoft, other.infoSoft, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      brandHover: Color.lerp(brandHover, other.brandHover, t)!,
      brandSoft: Color.lerp(brandSoft, other.brandSoft, t)!,
      brandSoft2: Color.lerp(brandSoft2, other.brandSoft2, t)!,
      brandText: Color.lerp(brandText, other.brandText, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
      sh1: _lerpShadows(sh1, other.sh1, t),
      sh2: _lerpShadows(sh2, other.sh2, t),
      sh3: _lerpShadows(sh3, other.sh3, t),
      brandFocus: _lerpShadows(brandFocus, other.brandFocus, t),
      readerPalette: readerPalette.lerp(other.readerPalette, t),
    );
  }

  static List<BoxShadow> _lerpShadows(
    List<BoxShadow> a,
    List<BoxShadow> b,
    double t,
  ) {
    final len = a.length < b.length ? a.length : b.length;
    return <BoxShadow>[
      for (var i = 0; i < len; i++) BoxShadow.lerp(a[i], b[i], t)!,
    ];
  }
}

/// 品牌色一组（内部用，避免 light/dark 两份构造器各写一遍字段）。
class _BrandPalette {
  const _BrandPalette(
    this.brand,
    this.brandHover,
    this.brandSoft,
    this.brandSoft2,
    this.brandText,
  );

  final Color brand;
  final Color brandHover;
  final Color brandSoft;
  final Color brandSoft2;
  final Color brandText;
}

_BrandPalette _brandOf(AppAccent accent, {required bool dark}) {
  switch (accent) {
    case AppAccent.terracotta:
      return dark
          ? const _BrandPalette(
              Color(0xFFE08A62),
              Color(0xFFEE9B75),
              Color(0xFF3A2119),
              Color(0xFF4D2B1F),
              Color(0xFFF0B294),
            )
          : const _BrandPalette(
              Color(0xFFB25430),
              Color(0xFF93421F),
              Color(0xFFF8E8DF),
              Color(0xFFF0D5C6),
              Color(0xFF8A3F22),
            );
    case AppAccent.teal:
      return dark
          ? const _BrandPalette(
              Color(0xFF35B8A3),
              Color(0xFF4BCBB5),
              Color(0xFF10342F),
              Color(0xFF17463F),
              Color(0xFF7FD9C9),
            )
          : const _BrandPalette(
              Color(0xFF0E7A6E),
              Color(0xFF0B5F57),
              Color(0xFFDCF0EC),
              Color(0xFFC2E5DE),
              Color(0xFF0A5A51),
            );
    case AppAccent.ink:
      return dark
          ? const _BrandPalette(
              Color(0xFF6FBB9F),
              Color(0xFF85CBB1),
              Color(0xFF16302A),
              Color(0xFF1D3D34),
              Color(0xFFA3D9C5),
            )
          : const _BrandPalette(
              Color(0xFF2F5D4F),
              Color(0xFF24493E),
              Color(0xFFDFEBE6),
              Color(0xFFC8DDD5),
              Color(0xFF23453B),
            );
  }
}

/// 便捷取用：`context.appTokens`。
extension AppDesignTokensContext on BuildContext {
  /// 当前主题的设计令牌（[AppTheme] 构建时挂载，一定存在）。
  AppDesignTokens get appTokens => Theme.of(this).extension<AppDesignTokens>()!;
}

// ===========================================================================
// 六、主题构建
// ===========================================================================

/// 主题工厂：把 [AppDesignTokens] 落成 Flutter [ThemeData]。
///
/// 刻意**不用** `ColorScheme.fromSeed`——那正是要消灭的塑料感来源；
/// 所有颜色都取自令牌表（原型 CSS 变量逐字对应）。
abstract final class AppTheme {
  /// 浅色主题。
  static ThemeData light(AppAccent accent) =>
      _build(AppDesignTokens.light(accent));

  /// 深色主题。
  static ThemeData dark(AppAccent accent) =>
      _build(AppDesignTokens.dark(accent));

  static ThemeData _build(AppDesignTokens t) {
    final scheme = t.isDark ? _darkScheme(t) : _lightScheme(t);
    return ThemeData(
      useMaterial3: true,
      brightness: t.brightness,
      colorScheme: scheme,
      // 字体族也落到 ThemeData 上：Material 自己拼的字（输入框、菜单、
      // 悬浮提示等）从 typography 继承字体族——只给 textTheme 槽位设族，
      // 这些控件仍会落回 'Roboto'（Windows 上不存在）→ 回退链又乱了。
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      scaffoldBackgroundColor: t.bg,
      canvasColor: t.bg,
      textTheme: _textTheme(t),
      extensions: <ThemeExtension<dynamic>>[t],
      // 交互态：品牌色淡染 + 表面色差，替代 Material 默认高饱和 ripple。
      hoverColor: t.surface3,
      focusColor: t.brand.withValues(alpha: 0.08),
      highlightColor: t.brand.withValues(alpha: 0.10),
      splashColor: t.brand.withValues(alpha: 0.06),
      // 组件主题
      appBarTheme: AppBarThemeData(
        backgroundColor: t.surface,
        foregroundColor: t.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // 标题样式**不覆盖**：留空则 Material 取 `textTheme.titleLarge`——
        // 它已由 textTheme 合并 typography 的字体族，并带上本套 h2 的字号/字重/色。
        // 直接写裸 `t.h2` 会丢掉 typography 的字体族，导致标题字体与全站不一致。
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: t.border),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.border, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationThemeData(
        filled: true,
        fillColor: t.surface2,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s2,
        ),
        hintStyle: t.caption.copyWith(color: t.text3),
        labelStyle: t.sm.copyWith(color: t.text2),
        helperStyle: t.caption.copyWith(color: t.text3),
        errorStyle: t.caption.copyWith(color: t.danger),
        border: _inputBorder(t.border),
        enabledBorder: _inputBorder(t.border),
        focusedBorder: _inputBorder(t.brand, width: 1.5),
        errorBorder: _inputBorder(t.danger),
        focusedErrorBorder: _inputBorder(t.danger, width: 1.5),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: t.surface,
        selectedColor: t.brandSoft,
        disabledColor: t.surface2,
        side: BorderSide(color: t.border),
        labelStyle: t.sm.copyWith(color: t.text2),
        secondaryLabelStyle: t.sm.copyWith(color: t.text2),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s3,
          vertical: AppSpacing.s1,
        ),
        shape: const StadiumBorder(),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        barrierColor: t.scrim,
        titleTextStyle: t.h3,
        contentTextStyle: t.body,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: BorderSide(color: t.border),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        textStyle: t.body,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(t.body),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: BorderSide(color: t.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: t.text,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: t.caption.copyWith(color: t.textInv),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.text,
        contentTextStyle: t.body.copyWith(color: t.textInv),
        actionTextColor: t.brandSoft,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: t.text2,
        textColor: t.text,
        titleTextStyle: t.body,
        subtitleTextStyle: t.caption,
      ),
      iconTheme: IconThemeData(color: t.text2, size: 20),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.brandSoft,
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(t.micro),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: t.surface,
        indicatorColor: t.brandSoft,
        elevation: 0,
        selectedIconTheme: IconThemeData(color: t.brandText),
        unselectedIconTheme: IconThemeData(color: t.text2),
        selectedLabelTextStyle: t.micro.copyWith(color: t.brandText),
        unselectedLabelTextStyle: t.micro.copyWith(color: t.text2),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: t.brand,
        unselectedLabelColor: t.text2,
        indicatorColor: t.brand,
        dividerColor: t.border,
        labelStyle: t.sm.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: t.sm,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll<Color>(t.surface),
        trackColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) return t.brand;
          return t.surface3;
        }),
        trackOutlineColor: WidgetStatePropertyAll<Color>(t.borderStrong),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) return t.brand;
          return Colors.transparent;
        }),
        checkColor: const WidgetStatePropertyAll<Color>(Colors.white),
        side: BorderSide(color: t.borderStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.selected)) return t.brand;
          return t.surface;
        }),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.brand,
        linearTrackColor: t.surface3,
        circularTrackColor: t.surface3,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: t.brand,
        inactiveTrackColor: t.surface3,
        thumbColor: t.brand,
        overlayColor: t.brand.withValues(alpha: 0.12),
        trackHeight: 3,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.brand,
        foregroundColor: _onBrand(t),
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: t.danger,
        textColor: Colors.white,
        textStyle: t.micro,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: t.text2,
        collapsedIconColor: t.text3,
        textColor: t.text,
        collapsedTextColor: t.text,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(AppRadius.lg),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll<TextStyle>(t.sm),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: t.border)),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: t.brand,
        selectionColor: t.brand.withValues(alpha: 0.25),
        selectionHandleColor: t.brand,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(t.surface),
          side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: t.border)),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              side: BorderSide(color: t.border),
            ),
          ),
        ),
      ),
    );
  }

  static OutlineInputBorder _inputBorder(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.md),
      borderSide: BorderSide(color: color, width: width),
    );
  }

  /// 主色上的可读文字色：品牌色为深色时用白，反之亦然。
  static Color _onBrand(AppDesignTokens t) {
    return t.isDark ? const Color(0xFF06231F) : Colors.white;
  }

  /// 字阶 → Material 槽位映射：全局不再出现 9px/10px 角标。
  static TextTheme _textTheme(AppDesignTokens t) {
    return TextTheme(
      displayLarge: t.display,
      displayMedium: t.h1,
      displaySmall: t.h2,
      headlineLarge: t.h1,
      headlineMedium: t.h1,
      headlineSmall: t.h2,
      titleLarge: t.h2,
      titleMedium: t.h3,
      titleSmall: t.h3,
      bodyLarge: t.body,
      bodyMedium: t.body,
      bodySmall: t.sm,
      labelLarge: t.sm,
      labelMedium: t.micro,
      labelSmall: t.caption,
    );
  }

  static ColorScheme _lightScheme(AppDesignTokens t) {
    return ColorScheme.light(
      primary: t.brand,
      onPrimary: Colors.white,
      primaryContainer: t.brandSoft,
      onPrimaryContainer: t.brandText,
      secondary: t.brandSoft2,
      onSecondary: t.brandText,
      secondaryContainer: t.brandSoft,
      onSecondaryContainer: t.brandText,
      tertiary: t.info,
      onTertiary: Colors.white,
      tertiaryContainer: t.infoSoft,
      onTertiaryContainer: t.info,
      error: t.danger,
      onError: Colors.white,
      errorContainer: t.dangerSoft,
      onErrorContainer: t.danger,
      surface: t.surface,
      onSurface: t.text,
      surfaceDim: t.surface3,
      surfaceBright: t.surface,
      surfaceContainerLowest: t.surface,
      surfaceContainerLow: t.surface2,
      surfaceContainer: t.surface2,
      surfaceContainerHigh: t.surface3,
      surfaceContainerHighest: t.surfaceInset,
      onSurfaceVariant: t.text2,
      outline: t.border,
      outlineVariant: t.borderStrong,
      shadow: const Color(0xFF1C1A16),
      scrim: t.scrim,
      inverseSurface: t.text,
      onInverseSurface: t.textInv,
      inversePrimary: t.brandHover,
      // 关掉 M3 的色调染（surfaceTint），保持中性表面不被主色染色。
      surfaceTint: Colors.transparent,
    );
  }

  static ColorScheme _darkScheme(AppDesignTokens t) {
    return ColorScheme.dark(
      primary: t.brand,
      onPrimary: const Color(0xFF06231F),
      primaryContainer: t.brandSoft,
      onPrimaryContainer: t.brandText,
      secondary: t.brandSoft2,
      onSecondary: t.brandText,
      secondaryContainer: t.brandSoft,
      onSecondaryContainer: t.brandText,
      tertiary: t.info,
      onTertiary: const Color(0xFF06231F),
      tertiaryContainer: t.infoSoft,
      onTertiaryContainer: t.info,
      error: t.danger,
      onError: const Color(0xFF2A0F0C),
      errorContainer: t.dangerSoft,
      onErrorContainer: t.danger,
      surface: t.surface,
      onSurface: t.text,
      surfaceDim: t.bg,
      surfaceBright: t.surface3,
      surfaceContainerLowest: t.bg,
      surfaceContainerLow: t.surfaceInset,
      surfaceContainer: t.surface,
      surfaceContainerHigh: t.surface2,
      surfaceContainerHighest: t.surface3,
      onSurfaceVariant: t.text2,
      outline: t.border,
      outlineVariant: t.borderStrong,
      shadow: Colors.black,
      scrim: t.scrim,
      inverseSurface: t.text,
      onInverseSurface: t.textInv,
      inversePrimary: t.brandHover,
      surfaceTint: Colors.transparent,
    );
  }
}
