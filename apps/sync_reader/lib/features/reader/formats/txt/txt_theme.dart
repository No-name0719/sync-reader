/// txt 阅读主题色映射（FR-202/FR-206）：ReaderTheme → 背景/正文/辅助色。
///
/// 供渲染器内部与集成阶段复用（如阅读页背景随主题联动）。
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

  /// [ReaderTheme] → txt 配色。纸色取 #F5EFDC 系。
  static TxtThemeColors of(ReaderTheme theme) => switch (theme) {
    ReaderTheme.light => const TxtThemeColors(
      background: Color(0xFFFFFFFF),
      foreground: Color(0xFF262626),
      dim: Color(0x99262626),
    ),
    ReaderTheme.dark => const TxtThemeColors(
      background: Color(0xFF121212),
      foreground: Color(0xFFC8C8C8),
      dim: Color(0x8AC8C8C8),
    ),
    ReaderTheme.paper => const TxtThemeColors(
      background: Color(0xFFF5EFDC),
      foreground: Color(0xFF43382A),
      dim: Color(0x9943382A),
    ),
  };
}
