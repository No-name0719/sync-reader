/// 主题映射（FR-206 → md）：三套调色板互异、设置透传（字号/行距/字体族）、
/// 代码块恒等宽。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/md/md_style.dart';

void main() {
  test('三种主题调色板背景/前景互异', () {
    final light = mdPaletteFor(ReaderTheme.light);
    final dark = mdPaletteFor(ReaderTheme.dark);
    final paper = mdPaletteFor(ReaderTheme.paper);
    expect(light.background, isNot(dark.background));
    expect(light.background, isNot(paper.background));
    expect(dark.background, isNot(paper.background));
    expect(light.foreground, isNot(dark.foreground));
  });

  test('字号/行距/字体族透传，代码恒等宽', () {
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
    expect(sheet.codeblockDecoration, isNotNull);
    expect(sheet.blockquoteDecoration, isNotNull);
    expect(sheet.tableBorder, isNotNull);
  });

  test('applySettings 等价构建：同设置同样式（幂等）', () {
    const settings = ReaderSettings(theme: ReaderTheme.paper, fontSize: 20);
    final a = buildMdStyleSheet(settings);
    final b = buildMdStyleSheet(settings);
    expect(a.p!.fontSize, b.p!.fontSize);
    expect(
      (a.codeblockDecoration! as BoxDecoration).color,
      (b.codeblockDecoration! as BoxDecoration).color,
    );
  });
}
