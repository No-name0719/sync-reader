/// epub 正文行盒测量（page 模式页界对齐用）。
///
/// 背景：epub 的 page 模式是**连续排版 + 吸附翻页**，页界一旦落在行的
/// 中间，该行就被拦腰切断（章节标题只显示上半截、页尾只显示半行）。
/// txt 用 [TxtPaginator] 逐行测量后切页，没有这个问题；epub 走 fwfh 渲染，
/// 行盒不对外暴露，只能**从已布局的渲染树反推**。
///
/// 做法：fwfh 的正文块最终落到 `RichText` → [RenderParagraph]，整段选区
/// 取回的盒数组按 **run** 切分（同一行的多个样式片段各一个盒），按「垂直
/// 重叠」归并成行盒。行盒 = 字体 ascent..descent 带（tight 盒高）。
///
/// 安全落点（[EpubLineBox.landing]）：行盒顶再上移一段安全余量——中日韩
/// 字面常高于字体的 ascent 带，只按行盒顶落点仍会削掉字形顶部（实测约
/// 0.15em）。余量取 [kEpubLandingMarginEm] × 字号，并夹在上一行行盒底之上
/// （行距过密时以不切上一行为准），故落点两侧都不压字形。
library;

import 'package:flutter/rendering.dart';

/// 行盒落点相对行盒顶的上移量（em 比例）：字形高出字体 ascent 带的余量。
///
/// 0.28em：中日韩字体 ascent 常为 0.86em 左右，字面可到 1.0em，高出约
/// 0.14em；再留一点余量即覆盖 antialiasing 溢出的一两像素。
const double kEpubLandingMarginEm = 0.28;

/// 一个文本行的行盒（相对所属块顶边的 y 区间）。
class EpubLineBox {
  const EpubLineBox({
    required this.top,
    required this.bottom,
    required this.landing,
  });

  /// 行盒顶（字体 ascent 带）。
  final double top;

  /// 行盒底（字体 descent 带）。
  final double bottom;

  /// 安全落点：行与行之间的可停靠位置（滚动到此处不切字）。
  final double landing;

  @override
  String toString() =>
      'EpubLineBox(top: ${top.toStringAsFixed(2)}, bottom: ${bottom.toStringAsFixed(2)}, '
      'landing: ${landing.toStringAsFixed(2)})';
}

/// 收集 [root] 渲染子树内所有文本行的行盒（相对 [root] 顶边，按 top 升序）。
///
/// - 遍历渲染树找 [RenderParagraph]（fwfh 的 `RichText` 产物）；
/// - 整段选区取行盒（run 级），按垂直重叠归并成行；
/// - 逐行算安全落点（行盒顶上移余量，且不低于上一行行盒底）；
/// - 段落为空或度量异常时跳过（不抛错：度量失败只是少了几个落点，
///   退回「视口高整数倍」的老落点也不会切字之外的任何东西）。
List<EpubLineBox> measureEpubLineBoxes(
  RenderBox root, {
  double baseFontSize = 0,
}) {
  final paragraphs = <RenderParagraph>[];
  void collect(RenderObject node) {
    if (node is RenderParagraph) paragraphs.add(node);
    node.visitChildren(collect);
  }

  collect(root);
  if (paragraphs.isEmpty) return const [];

  final rootTop = root.localToGlobal(Offset.zero).dy;
  final boxes = <EpubLineBox>[];
  for (final paragraph in paragraphs) {
    final paragraphTop = paragraph.localToGlobal(Offset.zero).dy - rootTop;
    final length = paragraph.text.toPlainText().length;
    if (length <= 0) continue;
    List<TextBox> lineBoxes;
    try {
      lineBoxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: length),
      );
    } catch (_) {
      // 断言失败（未布局）或引擎异常：该段不参与测量。
      continue;
    }
    final merged = _mergeByLine(lineBoxes);
    if (merged.isEmpty) continue;
    final fontSize = paragraph.text.style?.fontSize ?? baseFontSize;
    final margin = fontSize > 0 ? fontSize * kEpubLandingMarginEm : 0.0;
    var previousBottom = double.negativeInfinity;
    for (final box in merged) {
      var landing = box.top - margin;
      // 行距过密时以「不切上一行」为准（夹在上一行行盒底之上）。
      if (landing < previousBottom) landing = previousBottom;
      boxes.add(
        EpubLineBox(
          top: box.top + paragraphTop,
          bottom: box.bottom + paragraphTop,
          landing: landing + paragraphTop,
        ),
      );
      previousBottom = box.bottom;
    }
  }
  boxes.sort((a, b) => a.top.compareTo(b.top));
  return boxes;
}

/// 把 run 级盒归并成行级盒（同行的 run 盒垂直重叠——共享基线）。
List<EpubLineBox> _mergeByLine(List<TextBox> raw) {
  if (raw.isEmpty) return const [];
  final sorted = List<TextBox>.of(raw)
    ..sort((a, b) => a.top.compareTo(b.top));
  final merged = <EpubLineBox>[];
  for (final box in sorted) {
    if (merged.isNotEmpty && box.top < merged.last.bottom - 0.01) {
      // 与上一盒垂直重叠 → 同一行：取更高的顶、更低的底。
      final last = merged.removeLast();
      merged.add(
        EpubLineBox(
          top: last.top < box.top ? last.top : box.top,
          bottom: last.bottom > box.bottom ? last.bottom : box.bottom,
          landing: last.top,
        ),
      );
    } else {
      merged.add(
        EpubLineBox(top: box.top, bottom: box.bottom, landing: box.top),
      );
    }
  }
  return merged;
}
