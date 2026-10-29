/// md 阅读主题映射（FR-204/FR-206）：ReaderTheme（纸白/米黄/护眼/夜间）→
/// 调色板 + MarkdownStyleSheet；字号/行距/字体族从 ReaderSettings 透传。
///
/// v1.1（docs/10 A10/A11）：
/// - 色值权威源为 `core/design_tokens.dart` 的 `ReaderPalette`，本文件只做
///   角色映射（代码块底色/链接色由 palette 派生，不另立一份 bg/fg）；
/// - 正文段落两端对齐（`MarkdownStyleSheet.textAlign = spaceBetween` →
///   flutter_markdown_plus 对 p 块生成 `TextAlign.justify`）；
/// - 首行缩进 2em 由渲染器对段落块内容前置全角空格实现（等价 textIndent，
///   见 md_renderer.dart；不改 sourceStart/locator 坐标）；
/// - 衬线为默认正文字体（Q2，经 resolveReaderFont 解析）。
///
/// 显式构建（不依赖宿主 ThemeData），保证三端渲染一致、且 widget 可单测。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../contract/reader_settings.dart';

/// md 阅读调色板。
class MdPalette {
  const MdPalette({
    required this.background,
    required this.foreground,
    required this.secondary,
    required this.codeBackground,
    required this.border,
    required this.link,
  });

  /// 页面背景。
  final Color background;

  /// 正文前景。
  final Color foreground;

  /// 次要文本（图片占位说明、删除线等）。
  final Color secondary;

  /// 行内代码/代码块底色、图片占位底色。
  final Color codeBackground;

  /// 引用竖线 / 分隔线 / 表格线 / 代码块描边。
  final Color border;

  /// 链接色。
  final Color link;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MdPalette &&
          background == other.background &&
          foreground == other.foreground &&
          secondary == other.secondary &&
          codeBackground == other.codeBackground &&
          border == other.border &&
          link == other.link;

  @override
  int get hashCode => Object.hash(
    background,
    foreground,
    secondary,
    codeBackground,
    border,
    link,
  );
}

/// ReaderTheme → md 调色板。
///
/// bg/fg/muted/rule 直接取 design_tokens 权威 ReaderPalette；派生角色：
/// - codeBackground = 前景色 5% 叠加在背景上（跟随主题、四套互异）；
/// - link = 深色主题用提亮蓝、其余主题用标准蓝（markdown 链接语义色）。
MdPalette mdPaletteFor(ReaderTheme theme) {
  final palette = theme.palette;
  final isDark = theme == ReaderTheme.dark;
  return MdPalette(
    background: palette.bg,
    foreground: palette.fg,
    secondary: palette.muted,
    codeBackground: Color.alphaBlend(
      palette.fg.withValues(alpha: 0.05),
      palette.bg,
    ),
    border: palette.rule,
    link: isDark ? const Color(0xFF7CA9F5) : const Color(0xFF2563EB),
  );
}

/// 按 ReaderSettings 构建 md 样式表。
///
/// - 字号：正文 = [ReaderSettings.fontSize]，h1-h6 按比例缩放；
/// - 行距：正文 = [ReaderSettings.lineHeight]（标题固定紧凑行距）；
/// - 字体族：经 [resolveReaderFont] 解析（null = 衬线默认，Q2），代码块恒
///   等宽（FR-204 验收线之一，横向滚动由 flutter_markdown_plus 的 pre 元素内置）；
/// - 对齐：正文段落两端对齐（A10；spaceBetween 在 flutter_markdown_plus
///   中映射为 p 块的 TextAlign.justify）。
MarkdownStyleSheet buildMdStyleSheet(ReaderSettings settings) {
  final p = mdPaletteFor(settings.theme);
  final font = resolveReaderFont(settings.fontFamily);
  final base = TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    color: p.foreground,
    fontFamily: font.family,
    fontFamilyFallback: font.fallback,
  );
  final code = base.copyWith(
    fontFamily: 'monospace',
    fontSize: settings.fontSize * 0.9,
    backgroundColor: p.codeBackground,
  );
  TextStyle heading(double scale, {FontWeight weight = FontWeight.w700}) =>
      base.copyWith(
        fontSize: settings.fontSize * scale,
        height: 1.35,
        fontWeight: weight,
      );

  return MarkdownStyleSheet(
    a: TextStyle(color: p.link, decoration: TextDecoration.underline),
    p: base,
    // A10 两端对齐：flutter_markdown_plus 把 spaceBetween 映射为 p 块的
    // TextAlign.justify（标题/列表等其它块不受影响）。
    textAlign: WrapAlignment.spaceBetween,
    pPadding: EdgeInsets.zero,
    h1: heading(1.9),
    h2: heading(1.55),
    h3: heading(1.3),
    h4: heading(1.15),
    h5: heading(1.05, weight: FontWeight.w600),
    h6: heading(1.0, weight: FontWeight.w600),
    em: base.copyWith(fontStyle: FontStyle.italic),
    strong: base.copyWith(fontWeight: FontWeight.w700),
    del: base.copyWith(
      color: p.secondary,
      decoration: TextDecoration.lineThrough,
    ),
    blockquote: base,
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    blockquoteDecoration: BoxDecoration(
      border: Border(left: BorderSide(color: p.border, width: 3)),
      color: p.codeBackground.withValues(alpha: 0.6),
    ),
    code: code,
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: p.codeBackground,
      border: Border.all(color: p.border),
      borderRadius: BorderRadius.circular(6),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.border, width: 1)),
    ),
    listBullet: base,
    listIndent: settings.fontSize * 1.6,
    blockSpacing: settings.fontSize * 0.5,
    tableBorder: TableBorder.all(color: p.border),
    tableHead: base.copyWith(fontWeight: FontWeight.w700),
    tableBody: base,
    tableHeadAlign: TextAlign.center,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  );
}
