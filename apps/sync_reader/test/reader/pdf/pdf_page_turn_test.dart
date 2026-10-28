/// PdfReaderController 音量键翻页（FR-209）测试：相邻页经 pdfrx 跳页接口
/// （goToPage 语义，视图未挂载时走既有挂起跳转机制），边界页码返回 false。
///
/// 测试环境无 pdfium（无法打开真实 pdf 文档），pdfrx 文档以最小 fake 注入
/// （PdfDocument/PdfPage 均为可子类化的抽象类，控制器只消费 pages.length
/// 与页码状态，不触发渲染路径）。页码可观测点为 pageIndexListenable/percent。
library;

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_renderer.dart';

/// 最小 fake 页（只提供控制器消费的元数据）。
class _FakePdfPage extends pdfrx.PdfPage {
  _FakePdfPage(this._document, this.pageNumber);

  final pdfrx.PdfDocument _document;

  @override
  pdfrx.PdfDocument get document => _document;

  @override
  final int pageNumber;

  @override
  double get width => 612;

  @override
  double get height => 792;

  @override
  pdfrx.PdfPageRotation get rotation => pdfrx.PdfPageRotation.none;

  @override
  bool get isLoaded => true;

  @override
  Future<pdfrx.PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    Color? backgroundColor,
    pdfrx.PdfAnnotationRenderingMode annotationRenderingMode =
        pdfrx.PdfAnnotationRenderingMode.annotationAndForms,
    int flags = pdfrx.PdfPageRenderFlags.none,
    pdfrx.PdfPageRenderCancellationToken? cancellationToken,
  }) async => null;

  @override
  pdfrx.PdfPageRenderCancellationToken createCancellationToken() =>
      _FakeCancellationToken();

  @override
  Future<pdfrx.PdfPageText> loadText() async => throw UnimplementedError();

  @override
  Future<List<pdfrx.PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) async => const [];
}

class _FakeCancellationToken extends pdfrx.PdfPageRenderCancellationToken {
  var _canceled = false;

  @override
  void cancel() => _canceled = true;

  @override
  bool get isCanceled => _canceled;
}

/// 最小 fake 文档（固定页数；控制器只消费 pages.length）。
class _FakePdfDocument extends pdfrx.PdfDocument {
  _FakePdfDocument(int pageCount) : super(sourceName: 'fake:turn_test.pdf') {
    pages = List<pdfrx.PdfPage>.generate(
      pageCount,
      (i) => _FakePdfPage(this, i + 1),
    );
  }

  @override
  late final List<pdfrx.PdfPage> pages;

  @override
  Future<void> dispose() async {}

  @override
  Stream<pdfrx.PdfDocumentEvent> get events => const Stream.empty();

  @override
  bool get isEncrypted => false;

  @override
  pdfrx.PdfPermissions? get permissions => null;

  @override
  Future<List<pdfrx.PdfOutlineNode>> loadOutline() async => const [];

  @override
  bool isIdenticalDocumentHandle(Object? other) => identical(this, other);

  @override
  Future<void> loadPagesProgressively<T>({
    pdfrx.PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {}
}

PdfReaderController _openController(int pageCount) => PdfReaderController(
  document: _FakePdfDocument(pageCount),
  settings: ReaderSettings.defaults,
  initialAnchor: ProgressAnchor.empty,
);

void main() {
  test('nextPage/previousPage 相邻页翻页，首页与末页为边界 false', () async {
    final controller = _openController(5);
    addTearDown(controller.dispose);

    expect(controller.pageIndexListenable.value, 0);
    expect(await controller.previousPage(), isFalse, reason: '首页向前为边界');
    expect(controller.pageIndexListenable.value, 0);

    expect(await controller.nextPage(), isTrue);
    expect(controller.pageIndexListenable.value, 1);
    expect(controller.percent, closeTo(2 / 5, 1e-9), reason: 'percent=已读页占比');

    expect(await controller.previousPage(), isTrue);
    expect(controller.pageIndexListenable.value, 0);

    // 连续翻到末页（视图未挂载 → 每次落入挂起跳转，页码状态即时推进）。
    var moves = 0;
    while (await controller.nextPage()) {
      moves++;
      expect(moves, lessThan(10), reason: '防御死循环');
    }
    expect(controller.pageIndexListenable.value, 4, reason: '翻到末页');
    expect(moves, 4);
    expect(await controller.nextPage(), isFalse, reason: '末页向后为边界');
  });

  test('退化文档（0 页）：翻页恒为 false', () async {
    final controller = _openController(0);
    addTearDown(controller.dispose);

    expect(await controller.nextPage(), isFalse);
    expect(await controller.previousPage(), isFalse);
    expect(controller.pageIndexListenable.value, 0);
  });
}
