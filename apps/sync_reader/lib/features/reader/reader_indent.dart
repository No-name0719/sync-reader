/// 正文段首缩进（2em）的**行内占位符**（测量侧与渲染侧共用）。
///
/// ## 为什么不用空白字符
///
/// v1.1 起缩进用两个全角空格（U+3000）实现。实测（探针，字号 16、列宽
/// 720、正文两端对齐）：
/// - `U+3000×2 + 折行段落` → 首个可见字形 x = **0**（缩进被吞）；
/// - `U+3000×2 + 单行段落` → x = 32（缩进保留）。
///
/// 原因是**两端对齐时，被两端对齐的行（段落首行）会丢掉行首空白**，
/// 于是表现为「单行段落有缩进、折行段落没有」。换字符解决不了：
/// NBSP（U+00A0）在阅读字体里要么缺字形（Noto Serif/Sans SC 别名字体没有
/// 该字形），要么字宽不是 1em（微软雅黑只有 0.296em）；U+2060 / U+200B /
/// U+FEFF / U+2800 / U+3164 在仿宋/黑体/宋体/楷体/雅黑里全部缺字形。
///
/// ## 行内盒方案
///
/// 改用一个**宽度 = 2 × 字号、高 = 0、基线对齐**的不可见行内盒：
/// - 宽度由字号精确给出（2em），与字体无关；
/// - 不属于空白，不会被两端对齐吞掉（实测首字 x = 2em）；
/// - 高度为 0，不影响行高（实测行高与行数均不变 → 行网格不被破坏）。
///
/// ## 两侧尺寸必须一致
///
/// - 渲染侧（widget 树）：[readerIndentSpan] 的 child 会被自动量出尺寸；
/// - 测量侧（裸 `TextPainter`）：不会自动量，必须用
///   [readerIndentPlaceholder] 手动喂，数量须与占位符个数一致。
///
/// 两侧不一致会导致分页器算出的页界与渲染断行错位（页面内容溢出/被裁）。
library;

import 'package:flutter/widgets.dart';

/// 段首缩进的宽度（em 数）：2em = 两个全角字宽。
const int kReaderParagraphIndentEm = 2;

/// 缩进占位符的尺寸（**测量侧**用；与 [readerIndentSpan] 必须一致）。
PlaceholderDimensions readerIndentPlaceholder(double fontSize) =>
    PlaceholderDimensions(
      size: Size(fontSize * kReaderParagraphIndentEm, 0),
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      baselineOffset: 0,
    );

/// 缩进占位符（**渲染侧**用；widget 树会自动量出它的尺寸）。
WidgetSpan readerIndentSpan(double fontSize) => WidgetSpan(
      alignment: PlaceholderAlignment.baseline,
      baseline: TextBaseline.alphabetic,
      child: SizedBox(
        width: fontSize * kReaderParagraphIndentEm,
        height: 0,
      ),
    );
