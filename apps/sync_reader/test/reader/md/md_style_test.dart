/// 主题映射（FR-206 → md）：四套调色板互异、设置透传（字号/行距/字体族）、
/// 代码块恒等宽、正文两端对齐（A10）、色值权威源对齐 design_tokens（A11）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/md/md_style.dart';

void main() {
  test('四种主题调色板背景/前景互异（A11）', () {
    final palettes = ReaderTheme.values.map(mdPaletteFor).toList();
    for (var i = 0; i < palettes.length; i++) {
      for (var j = i + 1; j < palettes.length; j++) {
        expect(
          palettes[i].background,
          isNot(palettes[j].background),
          reason: '主题 $i 与 $j 背景应互异',
        );
        expect(
          palettes[i].foreground,
          isNot(palettes[j].foreground),
          reason: '主题 $i 与 $j 前景应互异',
        );
      }
    }
  });

  test('色值权威源 = design_tokens ReaderPalette（bg/fg/次级/描边）', () {
    for (final theme in ReaderTheme.values) {
      final palette = theme.palette;
      final md = mdPaletteFor(theme);
      expect(md.background, palette.bg);
      expect(md.foreground, palette.fg);
      expect(md.secondary, palette.muted);
      expect(md.border, palette.rule);
    }
  });

  test('字号/行距/字体族透传，代码恒等宽（默认衬线 Q2）', () {
    final sheet = buildMdStyleSheet(
      const ReaderSettings(fontSize: 22, lineHeight: 1.8, fontFamily: 'Serif'),
    );
    expect(sheet.p!.fontSize, 22);
    expect(sheet.p!.height, 1.8);
    expect(sheet.p!.fontFamily, 'Serif');
    expect(sheet.code!.fontFamily, 'monospace'); // FR-204 验收线
    expect(sheet.h1!.fontSize, greaterThan(sheet.p!.fontSize!));
    expect(sheet.h6!.fontSize, lessThan(sheet.h1!.fontSize!));
  });

  test('默认设置可构建样式表（无宿主 Theme 依赖）', () {
    final sheet = buildMdStyleSheet(ReaderSettings.defaults);
    expect(sheet.p, isNotNull);
    expect(sheet.p!.fontFamily, AppFonts.serif, reason: 'Q2 默认衬线');
    expect(sheet.codeblockDecoration, isNotNull);
    expect(sheet.blockquoteDecoration, isNotNull);
    expect(sheet.tableBorder, isNotNull);
  });

  test('正文段落两端对齐（A10：spaceBetween → p 块 justify）', () {
    final sheet = buildMdStyleSheet(ReaderSettings.defaults);
    // flutter_markdown_plus 的 _textAlignForBlockTag：spaceBetween → justify。
    expect(sheet.textAlign, WrapAlignment.spaceBetween);
  });

  test('applySettings 等价构建：同设置同样式（幂等）', () {
    const settings = ReaderSettings(theme: ReaderTheme.beige, fontSize: 20);
    final a = buildMdStyleSheet(settings);
    final b = buildMdStyleSheet(settings);
    expect(a.p!.fontSize, b.p!.fontSize);
    expect(
      (a.codeblockDecoration! as BoxDecoration).color,
      (b.codeblockDecoration! as BoxDecoration).color,
    );
  });
}
