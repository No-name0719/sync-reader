/// md 阅读主题映射（FR-204/FR-206）：ReaderTheme（light/dark/paper）→
/// 调色板 + MarkdownStyleSheet；字号/行距/字体族从 ReaderSettings 透传。
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
MdPalette mdPaletteFor(ReaderTheme theme) => switch (theme) {
  ReaderTheme.light => const MdPalette(
    background: Color(0xFFFFFFFF),
    foreground: Color(0xFF24292F),
    secondary: Color(0xFF6B7280),
    codeBackground: Color(0xFFF3F4F6),
    border: Color(0xFFD1D5DB),
    link: Color(0xFF2563EB),
  ),
  ReaderTheme.dark => const MdPalette(
    background: Color(0xFF17181C),
    foreground: Color(0xFFD8D5CE),
    secondary: Color(0xFF8A8F98),
    codeBackground: Color(0xFF24262C),
    border: Color(0xFF3A3D45),
    link: Color(0xFF7CA9F5),
  ),
  ReaderTheme.paper => const MdPalette(
    background: Color(0xFFF6F1E5),
    foreground: Color(0xFF3B3226),
    secondary: Color(0xFF8C7F6A),
    codeBackground: Color(0xFFEFE7D4),
    border: Color(0xFFD8CCB2),
    link: Color(0xFF8A5A2B),
  ),
};

/// 按 ReaderSettings 构建 md 样式表。
///
/// - 字号：正文 = [ReaderSettings.fontSize]，h1-h6 按比例缩放；
/// - 行距：正文 = [ReaderSettings.lineHeight]（标题固定紧凑行距）；
/// - 字体族：[ReaderSettings.fontFamily]（null = 平台默认），代码块恒等宽
///   （FR-204 验收线之一，横向滚动由 flutter_markdown_plus 的 pre 元素内置）。
MarkdownStyleSheet buildMdStyleSheet(ReaderSettings settings) {
  final p = mdPaletteFor(settings.theme);
  final base = TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    color: p.foreground,
    fontFamily: settings.fontFamily,
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
