/// epub 阅读主题色映射（FR-206）：ReaderTheme → 背景/正文/辅助色。
///
/// 与 txt_theme.dart 的三色语义一致（纸色取 #F5EFDC 系），
/// 供渲染器内部使用（正文 HtmlWidget 基础样式、容器背景、分隔线）。
library;

import 'package:flutter/material.dart';

import '../../contract/reader_settings.dart';

/// 一组主题色。
class EpubThemeColors {
  const EpubThemeColors({
    required this.background,
    required this.foreground,
    required this.dim,
  });

  /// 页面背景色。
  final Color background;

  /// 正文字色。
  final Color foreground;

  /// 辅助色（分隔线/图片占位等弱化元素）。
  final Color dim;

  /// [ReaderTheme] → epub 配色。
  static EpubThemeColors of(ReaderTheme theme) => switch (theme) {
    ReaderTheme.light => const EpubThemeColors(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF262626),
      dim: Color(0x99262626),
    ),
    ReaderTheme.dark => const EpubThemeColors(
      background: Color(0xFF121212),
      foreground: Color(0xFFC8C8C8),
      dim: Color(0x8AC8C8C8),
    ),
    ReaderTheme.paper => const EpubThemeColors(
      background: Color(0xFFF5EFDC),
      foreground: Color(0xFF43382A),
      dim: Color(0x9943382A),
    ),
  };
}
