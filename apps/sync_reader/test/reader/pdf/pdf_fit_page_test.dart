/// pdf「**整页进屏** + 滚轮步长」的回归测试（v1.4.6）。
///
/// 缺陷背景（用户实测）：
/// 1. **全屏时 pdf 只展示一页的一部分**——pdfrx 默认的初始缩放是
///    **cover scale**（页面按宽度铺满视口 → 页面比视口**高** → 一屏只看得到
///    页面的一部分），要手动缩到很窄才看得见整页；
/// 2. **滚轮滚动太慢**，每次只移动一点——pdfrx 默认
///    `scrollByMouseWheel = 0.2` → 每格只滚滚轮增量的 20%（约 20px）。
///
/// 本测试需要 **pdfium 原生库**（pdfrx 的唯一原生依赖）：
///
/// ```bash
/// cd apps/sync_reader
/// set PATH=%PATH%;%CD%\build\windows\x64\runner\Release   # Windows
/// flutter test test/reader/pdf/pdf_fit_page_test.dart
/// ```
///
/// 没有 pdfium 时**自动跳过**（不拖累常规 CI——见 CHANGELOG 里
/// 「markTestSkipped 后需显式中断用例体」的踩坑记录）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:sync_reader/features/reader/formats/pdf/pdf_renderer.dart';

/// 样章 PDF（仓库内自带，3 页 Letter 尺寸 612×792pt）。
const String _samplePdf = '../../testdata/book-sample.pdf';

void main() {
  test('初始缩放取整页适配：整页进屏（用真实 PDF 的页面尺寸复算）', () async {
    final doc = await _openPdf();
    if (doc == null) {
      // 无 pdfium 原生库 → 跳过（markTestSkipped 后需显式中断用例体）。
      markTestSkipped('需要 pdfium 原生库（见文件头说明）');
      return;
    }
    final page = doc.pages.first;
    final pageSize = Size(page.width, page.height);

    // 按 pdfrx 自己的口径复算两个缩放（源码见
    // packages/third_party/pdfrx/lib/src/widgets/pdf_viewer.dart 的
    // _calcCoverFitScale）。
    final view = const Size(1200, 800);
    final docSize = Size(
      doc.pages.map((p) => p.width).reduce((a, b) => a > b ? a : b),
      doc.pages.map((p) => p.height).reduce((a, b) => a + b),
    );
    final cover = coverScaleFor(view: view, document: docSize);
    final fit = fitScaleFor(view: view, page: pageSize);

    // 旧行为（pdfrx 默认取 cover）：页面按宽度铺满 → 页比视口**高** →
    // 一屏只看得到页面的一部分（用户实测：「全屏时 pdf 只会展示一页的
    // 一部分，需要缩放宽度后才能展示一页」）。
    expect(
      pageSize.height * cover,
      greaterThan(view.height),
      reason: '复算前提：cover 缩放下页面确实高于视口（否则这条用例测不出东西）',
    );
    // 新行为（取 fit）：整页进屏。
    expect(
      pageSize.height * fit,
      lessThanOrEqualTo(view.height + 0.5),
      reason: '整页适配后页面高 ${pageSize.height * fit} 应不超过视口高 '
          '${view.height}',
    );
    // 参数确实选了 fit。
    expect(selectInitialPdfZoom(fitZoom: fit, coverZoom: cover), fit);
  });

  testWidgets('滚轮步长 1.0（每格约 100px，不再是 20px）', (tester) async {
    final params = buildPdfViewerParams(
      backgroundColor: const Color(0xFFEFEEE9),
      onPageChanged: (_) {},
      onViewerReady: (_, _) {},
    );
    expect(
      params.scrollByMouseWheel,
      1.0,
      reason: 'pdfrx 默认 0.2 → 每格只滚约 20px，读起来「每次只移动一点」',
    );
  });

  group('初始缩放策略（纯函数）', () {
    test('取 fit（整页适配），不取 cover（铺满）', () {
      expect(
        selectInitialPdfZoom(fitZoom: 0.8, coverZoom: 1.4),
        0.8,
        reason: '必须取 fit：cover 会让页面比视口高，一屏只看得到一部分',
      );
    });
  });
}

/// 打开样章 PDF；**没有 pdfium 原生库时返回 null**（用例自行跳过）。
Future<pdfrx.PdfDocument?> _openPdf() async {
  final file = File(_samplePdf);
  if (!file.existsSync()) return null;
  try {
    return await pdfrx.PdfDocument.openFile(file.path);
  } catch (_) {
    // pdfium 加载失败（测试环境无原生库）→ 跳过，不算失败。
    return null;
  }
}

/// pdfrx 的「铺满」缩放（`_calcCoverFitScale`）：max(宽比, 高比)。
double coverScaleFor({required Size view, required Size document}) =>
    math.max(view.width / document.width, view.height / document.height);

/// pdfrx 的「整页适配」缩放（`_calcCoverFitScale`）：min(宽比, 高比)，
/// 边距按 [PdfViewerParams.margin] 的默认值 8 计。
double fitScaleFor({
  required Size view,
  required Size page,
  double margin = 8.0,
}) {
  final m2 = margin * 2;
  return math.min(
    (view.width - m2) / page.width,
    (view.height - m2) / page.height,
  );
}
