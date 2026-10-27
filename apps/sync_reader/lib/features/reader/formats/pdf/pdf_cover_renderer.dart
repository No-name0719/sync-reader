/// pdf 封面渲染（FR-103）：首页缩略图 → PNG 字节。
///
/// pdfrx 调用收敛到可注入的 [PdfCoverRenderer] 函数类型：
/// - flutter test 环境无 pdfium.dll，真实打开 pdf 必然抛异常——测试注入
///   fake 渲染函数即可覆盖封面成功/失败路径，无需真实渲染；
/// - 生产走 [renderPdfFirstPageCover] 默认实现（pdfrx 1.3.5，API 形态以
///   `packages/third_party/pdfrx` 本地源码为准）。
///
/// 渲染约定：只渲染第 1 页、目标宽约 360px 等比缩放（导入期低开销）；
/// 白底渲染（`backgroundColor` 显式给白，透明背景合成白色，避免书库
/// 深色主题下透明页显示为黑块）。打开失败/加密/损坏/零页 → 抛异常或
/// 返回 null，由调用方（handler）统一降级为无封面，绝不阻塞导入。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' show Colors;
import 'package:pdfrx/pdfrx.dart' as pdfrx;

/// 封面渲染函数类型：输入 pdf 文件路径，输出首页 PNG 字节。
///
/// 返回 null 表示"无封面"（如零页文档）；抛异常表示"渲染失败"——两者
/// 均由 handler 捕获降级，契约上等价。
typedef PdfCoverRenderer = Future<Uint8List?> Function(String path);

/// 封面目标宽度（像素；高度按首页纵横比换算）。
///
/// 书库网格缩略图显示尺寸的约 1.5 倍，兼顾清晰度与导入耗时/文件体积。
const double pdfCoverTargetWidth = 360;

/// 默认封面渲染实现：pdfrx 打开文档 → 渲染第 1 页 → PNG 字节。
///
/// 注意（1.3.5 render 语义）：`fullWidth/fullHeight` 是页面虚拟全尺寸、
/// `width/height` 是输出位图尺寸；只传 width 会渲染左上角子区而非整页，
/// 故必须成对给出 fullWidth/fullHeight（宽高一致时输出即为整页）。
Future<Uint8List?> renderPdfFirstPageCover(String path) async {
  final document = await pdfrx.PdfDocument.openFile(path);
  try {
    final pages = document.pages;
    if (pages.isEmpty) return null; // 零页文档：无封面。
    final page = pages.first;
    final fullHeight = page.width > 0
        ? pdfCoverTargetWidth * page.height / page.width
        : // 宽度异常时按 A4 纵横比兜底。
          pdfCoverTargetWidth * 1.414;
    final rendered = await page.render(
      fullWidth: pdfCoverTargetWidth,
      fullHeight: fullHeight,
      backgroundColor: Colors.white, // 透明背景合成白色。
    );
    if (rendered == null) return null;
    try {
      final image = await rendered.createImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data?.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  } finally {
    await document.dispose();
  }
}
