/// txt 阅读主题色映射（FR-202/FR-206）：ReaderTheme → 背景/正文/辅助色。
///
/// v1.1（docs/10 A11）：色值权威源为 `core/design_tokens.dart` 的
/// `ReaderPalette`（纸白/米黄/护眼/夜间 四套），本文件只做角色映射，
/// 不再自带色值——三格式共用同一权威，避免各写一份。
library;

import 'package:flutter/material.dart';

import '../../contract/reader_settings.dart';

/// 一组主题色。
class TxtThemeColors {
  const TxtThemeColors({
    required this.background,
    required this.foreground,
    required this.dim,
  });

  /// 页面背景色。
  final Color background;

  /// 正文字色。
  final Color foreground;

  /// 辅助色（页脚章题/进度等弱化信息）。
  final Color dim;

  /// [ReaderTheme] → txt 配色（取 design_tokens 的权威 ReaderPalette）。
  static TxtThemeColors of(ReaderTheme theme) {
    final palette = theme.palette;
    return TxtThemeColors(
      background: palette.bg,
      foreground: palette.fg,
      dim: palette.muted,
    );
  }
}
