/// epub 阅读主题色映射（FR-206）：ReaderTheme → 背景/正文/辅助色。
///
/// v1.1（docs/10 A11）：色值权威源为 `core/design_tokens.dart` 的
/// `ReaderPalette`（纸白/米黄/护眼/夜间 四套），与 txt_theme 同一权威，
/// 本文件只做角色映射（正文 HtmlWidget 基础样式、容器背景、分隔线）。
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

  /// [ReaderTheme] → epub 配色（取 design_tokens 的权威 ReaderPalette）。
  static EpubThemeColors of(ReaderTheme theme) {
    final palette = theme.palette;
    return EpubThemeColors(
      background: palette.bg,
      foreground: palette.fg,
      dim: palette.muted,
    );
  }
}
