/// 阅读主题对比度门（v1.2 B2/B3 验收线）：
/// - 7 套主题：正文 fg/bg ≥ 7:1（AAA），次级 muted/bg ≥ 4.5:1（AA）；
/// - 夜间系（深灰/深棕/纯黑）在最低亮度 80% 下仍达上述标准（B3：
///   亮度作用整屏——背景与正文按同系数缩放后重算）。
///
/// 对比度按 WCAG 2.1 相对亮度公式实算（design_tokens 的
/// [wcagContrastRatio]），色值改动若破坏达标会在此失败。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';

/// 与渲染端 B3 亮度矩阵同口径的整屏缩放（sRGB 通道 × 系数）。
Color _scaled(Color c, double f) => scaleColorBrightness(c, f);

/// 夜间系最低亮度（与 ReaderSettings 面板滑杆下限一致）。
const double _minNightBrightness = 0.8;

void main() {
  group('阅读主题对比度门（WCAG 2.1 实算）', () {
    test('7 套主题：正文 ≥7:1（AAA）、次级 ≥4.5:1（AA）', () {
      for (final theme in AppReaderTheme.values) {
        final palette = theme.palette;
        expect(
          palette.fgContrast,
          greaterThanOrEqualTo(7.0),
          reason: '${theme.label}（${theme.name}）正文对比度应达 AAA',
        );
        expect(
          palette.mutedContrast,
          greaterThanOrEqualTo(4.5),
          reason: '${theme.label}（${theme.name}）次级文字对比度应达 AA',
        );
      }
    });

    test('夜间系 80% 最低亮度：整屏缩放后正文仍 ≥7:1、次级仍 ≥4.5:1', () {
      final nightThemes = AppReaderTheme.values
          .where((t) => t.isNight)
          .toList();
      expect(nightThemes.length, 3, reason: '夜间系 = 深灰/深棕/纯黑');
      for (final theme in nightThemes) {
        final p = theme.palette;
        final fg = _scaled(p.fg, _minNightBrightness);
        final muted = _scaled(p.muted, _minNightBrightness);
        final bg = _scaled(p.bg, _minNightBrightness);
        final fgRatio = wcagContrastRatio(fg, bg);
        final mutedRatio = wcagContrastRatio(muted, bg);
        expect(
          fgRatio,
          greaterThanOrEqualTo(7.0),
          reason: '${theme.label} 80% 亮度下正文对比度 ${fgRatio.toStringAsFixed(2)} 应达 AAA',
        );
        expect(
          mutedRatio,
          greaterThanOrEqualTo(4.5),
          reason: '${theme.label} 80% 亮度下次级对比度 ${mutedRatio.toStringAsFixed(2)} 应达 AA',
        );
      }
    });

    test('wcagContrastLevel 等级文案', () {
      expect(wcagContrastLevel(7.0), 'AAA');
      expect(wcagContrastLevel(4.5), 'AA');
      expect(wcagContrastLevel(3.0), 'AA（仅大字）');
      expect(wcagContrastLevel(2.9), '不合格');
    });

    test('scaleColorBrightness：系数 1 不变色、缩放按 sRGB 通道钳制', () {
      const c = Color(0xFFC8CACD);
      expect(scaleColorBrightness(c, 1.0), c);
      // 0xFF * 0.5 = 127.5 → round 128（0x80）
      expect(scaleColorBrightness(const Color(0xFFFF0000), 0.5).r * 255.0, 0x80);
      expect(scaleColorBrightness(c, 0.8).r * 255.0, (0xC8 * 0.8).round());
    });
  });
}
