/// 段首缩进回归测试（B6-1）：两端对齐下**折行段落**也必须有 2em 首行缩进。
///
/// 背景（v1.3 修复）：缩进原用两个全角空格（U+3000）实现，而两端对齐时
/// 被两端对齐的行（段落首行）会丢掉行首空白 → 折行段落的缩进消失
/// （实测首字 x = 0），单行段落却保留。改用**行内不可见盒**（宽 2em、
/// 高 0、基线对齐）后两种段落一致（实测首字 x = 2em）。
///
/// 本文件锁定的三条不变量：
/// 1. 折行段落的首字 x == 2em；
/// 2. 单行段落的首字 x == 2em（与折行段落一致）；
/// 3. 关闭缩进后首字 x == 0。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/reader_indent.dart';

const double _fontSize = 16;
const double _lineHeight = 1.95;
const double _width = 720;

/// 两端对齐 + 一个会折行的段落。
final TextSpan _wrappedSpan = TextSpan(
  style: const TextStyle(fontSize: _fontSize, height: _lineHeight),
  children: [
    readerIndentSpan(_fontSize),
    const TextSpan(
      text: '天还没有亮透，落在瓦上的雪先有了声音。细而密，像有人在屋顶上筛一把碎米，'
          '簌簌地落了半夜。林砚是被这声音叫醒的，他睁开眼，看见窗纸上一片淡白。',
    ),
  ],
);

/// 两端对齐 + 一个不折行的短段落。
final TextSpan _singleSpan = TextSpan(
  style: const TextStyle(fontSize: _fontSize, height: _lineHeight),
  children: [
    readerIndentSpan(_fontSize),
    const TextSpan(text: '雪大。'),
  ],
);

/// 首个可见字形的 x（跳过行内占位符 U+FFFC）。
double _firstGlyphX(TextPainter painter) {
  final flat = painter.text!.toPlainText();
  var i = 0;
  while (i < flat.length && flat.codeUnitAt(i) == 0xFFFC) {
    i++;
  }
  final boxes = painter.getBoxesForSelection(
    TextSelection(baseOffset: i, extentOffset: i + 1),
  );
  return boxes.isEmpty ? -1 : boxes.first.left;
}

TextPainter _measure(TextSpan span, {int indentCount = 1}) {
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.justify,
    text: span,
  );
  painter.setPlaceholderDimensions(
    List<PlaceholderDimensions>.filled(
      indentCount,
      readerIndentPlaceholder(_fontSize),
    ),
  );
  painter.layout(maxWidth: _width);
  return painter;
}

void main() {
  test('两端对齐下折行段落有 2em 首行缩进', () {
    final painter = _measure(_wrappedSpan);
    final x = _firstGlyphX(painter);
    painter.dispose();
    expect(x, closeTo(_fontSize * 2, 0.5), reason: '折行段落首字 x 应为 2em');
  });

  test('单行段落与折行段落的缩进一致（同为 2em）', () {
    final single = _measure(_singleSpan);
    final wrapped = _measure(_wrappedSpan);
    final x1 = _firstGlyphX(single);
    final x2 = _firstGlyphX(wrapped);
    single.dispose();
    wrapped.dispose();
    expect(x1, closeTo(x2, 0.5), reason: '单行与折行段落的缩进应一致');
    expect(x1, closeTo(_fontSize * 2, 0.5));
  });

  test('关闭缩进后首字贴左（x = 0）', () {
    final span = TextSpan(
      style: const TextStyle(fontSize: _fontSize, height: _lineHeight),
      children: [
        const TextSpan(
          text: '天还没有亮透，落在瓦上的雪先有了声音。细而密，像有人在屋顶上筛一把碎米，'
              '簌簌地落了半夜。林砚是被这声音叫醒的，他睁开眼，看见窗纸上一片淡白。',
        ),
      ],
    );
    final painter = _measure(span, indentCount: 0);
    final x = _firstGlyphX(painter);
    painter.dispose();
    expect(x, closeTo(0, 0.5));
  });

  test('显示层变换：每段首行一个缩进占位符（纯文本里是 1 个 U+FFFC）', () {
    const text = '第一段。\n第二段。';
    final build = buildTxtDisplaySpans(
      text,
      0,
      text.length,
      style: const TextStyle(fontSize: _fontSize, height: _lineHeight),
      fontSize: _fontSize,
    );
    expect(build.indentCount, 2, reason: '两个段落首行各一个占位符');
    final plain = build.span.toPlainText();
    expect(plain, '￼第一段。\n￼第二段。');
  });
}
