/// 章题样式回归测试（v1.4）：章题行用**标题样式**渲染（1.32em / 600），
/// 行盒高度仍等于正文的一行高（行网格不被破坏），且章题不缩进。
///
/// 原型规格（`ui_prototype/reader.css`）：
/// `.rd-text .rd-chapter-title{font-size:1.32em;font-weight:600;
///   line-height:var(--rd-lh-px);text-indent:0;letter-spacing:.02em}`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/reader_indent.dart';

const double _fontSize = 16;
const double _lineHeight = 1.95;

const TextStyle _base = TextStyle(fontSize: _fontSize, height: _lineHeight);

TextSpan _spanFor(String chapterText) => txtDisplaySpan(
      chapterText,
      0,
      chapterText.length,
      style: _base,
      fontSize: _fontSize,
    );

void main() {
  test('章题行用标题样式：1.32em / 600 / 字距 0.02em', () {
    final span = _spanFor('第1章 落雪\n天还没有亮透。');
    final first = span.children!.first as TextSpan;
    expect(first.text, '第1章 落雪');
    expect(first.style!.fontSize, closeTo(_fontSize * 1.32, 0.001));
    expect(first.style!.fontWeight, FontWeight.w600);
    expect(first.style!.letterSpacing, closeTo(_fontSize * 0.02, 0.001));
  });

  test('章题行的行盒高度 = 正文一行高（行网格不破）', () {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: _spanFor('第1章 落雪\n天还没有亮透。'),
    );
    painter.setPlaceholderDimensions(
      [readerIndentPlaceholder(_fontSize)],
    );
    painter.layout(maxWidth: 720);
    final metrics = painter.computeLineMetrics();
    expect(metrics.length, 2, reason: '章题一行 + 正文一行');
    // 章题行（首行）的行盒高度必须与正文行一致（行网格不破）。
    expect(
      metrics[0].height,
      closeTo(metrics[1].height, 0.01),
      reason: '章题行与正文行的行盒高度应一致（行网格不破）',
    );
    // 且等于纯正文排版的行高。
    final plainPainter = TextPainter(
      textDirection: TextDirection.ltr,
      text: const TextSpan(text: '天还没有亮透。', style: _base),
    )..layout(maxWidth: 720);
    final plainHeight = plainPainter.computeLineMetrics().first.height;
    plainPainter.dispose();
    expect(
      metrics[0].height,
      closeTo(plainHeight, 0.01),
      reason: '章题行高应等于纯正文的行高',
    );
    painter.dispose();
  });

  test('章题不缩进（其后的正文段缩进 2em）', () {
    final span = _spanFor('第1章 落雪\n天还没有亮透。');
    final plain = span.toPlainText();
    expect(plain.startsWith('第1章 落雪'), isTrue, reason: '章题前无缩进占位符');
    expect(plain.contains('\n￼天还没有亮透。'), isTrue, reason: '正文段有 2em 缩进');
  });

  test('非标题行不套用标题样式（章起始行不是标题时）', () {
    final span = _spanFor('这是普通正文的第一行。\n第二段。');
    // 首个子节点是缩进占位符（正文段起点），且**没有任何**子节点套用标题样式。
    var headingStyled = 0;
    span.visitChildren((child) {
      if (child is TextSpan &&
          child.style?.fontSize != null &&
          (child.style!.fontSize! - _fontSize * 1.32).abs() < 0.001) {
        headingStyled++;
      }
      return true;
    });
    expect(headingStyled, 0, reason: '普通正文行不应套用章题样式');
  });
}
