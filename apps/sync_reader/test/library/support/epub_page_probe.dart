/// epub page 模式页停探针（测试用）。
///
/// page 模式的页界必须落在**行与行之间**（行盒顶），否则行被页界拦腰
/// 切断（章题只显示上半截 / 页尾只显示半行）。本文件从已构建块的渲染树
/// 量出全部行盒，供测试断言：
/// - 落点是**已知行边界**（比「视口高整数倍」更强：视口高整数倍通常落在
///   行的中间）；
/// - 落点处**没有行盒横跨**（即没有字形被裁切）。
library;

import 'package:flutter/rendering.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_line_meter.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

/// 文档坐标系下全部已构建块的行盒（升序）。
///
/// 文档坐标 = 视口顶在整书内容中的 y（滚动偏移即该坐标）。
List<EpubLineBox> epubDocumentLineBoxes(EpubRenderer renderer) {
  final viewportBox =
      renderer.viewportKey.currentContext?.findRenderObject() as RenderBox?;
  if (viewportBox == null || !viewportBox.hasSize) return const [];
  final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
  final base = renderer.scrollController.hasClients
      ? renderer.scrollController.offset
      : 0.0;
  final boxes = <EpubLineBox>[];
  for (var i = 0; i < renderer.blockCount; i++) {
    final context = renderer.blockContextOf(i);
    if (context == null) continue;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) continue;
    final top = base + box.localToGlobal(Offset.zero).dy - viewportTop;
    if (_isImageBlock(renderer, i)) continue;
    for (final line in measureEpubLineBoxes(box)) {
      boxes.add(
        EpubLineBox(
          top: top + line.top,
          bottom: top + line.bottom,
          landing: top + line.landing,
        ),
      );
    }
  }
  boxes.sort((a, b) => a.top.compareTo(b.top));
  return boxes;
}

/// 文档坐标系下的全部页停候选（安全落点 + 图片块块顶，升序）。
List<double> epubDocumentStops(EpubRenderer renderer) {
  final viewportBox =
      renderer.viewportKey.currentContext?.findRenderObject() as RenderBox?;
  if (viewportBox == null || !viewportBox.hasSize) return const [];
  final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
  final base = renderer.scrollController.hasClients
      ? renderer.scrollController.offset
      : 0.0;
  final stops = <double>[];
  for (var i = 0; i < renderer.blockCount; i++) {
    final context = renderer.blockContextOf(i);
    if (context == null) continue;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) continue;
    final top = base + box.localToGlobal(Offset.zero).dy - viewportTop;
    if (_isImageBlock(renderer, i)) {
      stops.add(top);
      continue;
    }
    for (final line in measureEpubLineBoxes(box)) {
      stops.add(top + line.landing);
    }
  }
  stops.sort();
  return stops;
}

/// 横跨 [offset] 的行盒——即落点处被裁切的行（应为空）。
///
/// 判据用**字形带**（行盒顶..行盒底，字体 ascent..descent 带）：落点落在
/// 任何一行字形带内部即视为该行被切。
List<EpubLineBox> epubCutLines(EpubRenderer renderer, double offset) {
  return epubDocumentLineBoxes(
    renderer,
  ).where((l) => l.top < offset - 0.5 && l.bottom > offset + 0.5).toList();
}

/// 块是否为图片块（整页槽）：无文字且含 img。
bool _isImageBlock(EpubRenderer renderer, int index) {
  final html = renderer.blockHtml(index);
  final text = renderer.blockPlainText(index).trim();
  return text.isEmpty && html.contains('<img');
}
