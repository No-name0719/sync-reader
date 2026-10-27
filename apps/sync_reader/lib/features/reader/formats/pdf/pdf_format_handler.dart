/// pdf 格式处理器（FR-205 / FR-102）：元数据解析（outline 目录 + 首页封面）
/// 与渲染器创建。
///
/// 解析约定（契约，见 `FormatHandlerBase`）：**解析失败不得抛出**——
/// flutter test 环境无 pdfium.dll、损坏/加密文件等一律捕获后降级为
/// 文件名元数据 + 空目录，绝不阻塞书库导入。
///
/// 指纹约定：有 outline 时对 toc 指纹；无 outline 时对页数指纹
/// （`pagesFingerprintEntry`），保证跨端对同一文件产出一致指纹。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/parsed_book.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_fingerprint.dart';
import '../common/file_name_parser.dart';
import '../handler_base.dart';
import 'pdf_outline_mapper.dart';
import 'pdf_renderer.dart';

export 'pdf_page_anchor.dart';

/// 封面渲染的目标宽度（逻辑像素；高度按页面纵横比换算）。
const _coverWidth = 320.0;

/// 内部解析产物：[ParsedContent] + 页数（指纹用；解析失败为 null）。
class _ParsedPdf {
  const _ParsedPdf(this.content, this.pageCount);

  /// 退化产物（文件名兜底）。
  const _ParsedPdf.fallback() : this(ParsedContent.empty, null);

  final ParsedContent content;

  /// 打开成功时的总页数；未打开成功为 null。
  final int? pageCount;
}

/// pdf 格式处理器。
class PdfFormatHandler extends FormatHandlerBase {
  @override
  String get formatId => 'pdf';

  @override
  Set<String> get extensions => {'pdf'};

  @override
  bool canHandle(String ext, Uint8List magicHeader) {
    if (!super.canHandle(ext, magicHeader)) return false;
    // 空头部（未提供魔数）不得误判为不支持；有头部时校验 `%PDF-` 前缀。
    if (magicHeader.isEmpty) return true;
    const magic = [0x25, 0x50, 0x44, 0x46, 0x2D]; // "%PDF-"
    final n = magicHeader.length < magic.length
        ? magicHeader.length
        : magic.length;
    for (var i = 0; i < n; i++) {
      if (magicHeader[i] != magic[i]) return false;
    }
    return true;
  }

  /// 解析 pdf 元数据（带页数指纹约定，见库注释）。
  ///
  /// 覆盖基类实现的原因：基类指纹恒为 `compute(toc)`，而 pdf 无 outline 时
  /// 需要对**页数**指纹（跨端一致），空 toc 的哈希无法区分不同书。
  @override
  Future<ParsedBook> parseMetadata(BookFile file) async {
    final nameMeta = parseBookFileName(file.fileName);
    _ParsedPdf parsed;
    try {
      parsed = await _parse(file);
    } catch (e, s) {
      log.warn('${file.fileName}：PDF 解析失败，降级为文件名元数据+空目录');
      log.error('PDF 解析异常详情', e, s);
      parsed = const _ParsedPdf.fallback();
    }
    final toc = parsed.content.toc;
    final fingerprint = toc.isEmpty
        ? TocFingerprint.compute([pagesFingerprintEntry(parsed.pageCount ?? 0)])
        : TocFingerprint.compute(toc);
    return ParsedBook(
      title: parsed.content.title ?? nameMeta.title,
      author: parsed.content.author ?? nameMeta.author,
      toc: toc,
      tocFingerprint: fingerprint,
      language: parsed.content.language,
      coverBytes: parsed.content.coverBytes,
    );
  }

  @override
  Future<ParsedContent> parseContent(BookFile file) async =>
      (await _parse(file)).content;

  Future<_ParsedPdf> _parse(BookFile file) async {
    final document = await pdfrx.PdfDocument.openFile(file.path);
    try {
      final pageCount = document.pages.length;
      // 注意：pdfrx 的 FFI 有专属后台 worker，切勿将 document 调用包进 compute()。
      final outline = await document.loadOutline();
      final toc = outlineItemsToTocEntries(flattenPdfOutline(outline));
      Uint8List? cover;
      try {
        cover = await _renderCover(document);
      } catch (e, s) {
        log.warn('${file.fileName}：封面渲染失败，忽略（不影响导入）');
        log.error('封面渲染异常详情', e, s);
      }
      // pdf 无可靠语言字段（Info dict 未暴露）→ language 置空。
      return _ParsedPdf(ParsedContent(coverBytes: cover, toc: toc), pageCount);
    } finally {
      await document.dispose();
    }
  }

  /// 首页渲染为 PNG 封面：整页按 320px 宽等比渲染 → ui.Image → PNG 字节。
  Future<Uint8List?> _renderCover(pdfrx.PdfDocument document) async {
    final pages = document.pages;
    if (pages.isEmpty) return null;
    final page = pages.first;
    // render 语义（1.3.5 源码）：fullWidth/fullHeight 为页面虚拟全尺寸，
    // width/height 为输出位图尺寸；只传 width 会渲染左上角子区而非整页，
    // 故必须成对给出 fullWidth/fullHeight。
    final fullWidth = _coverWidth;
    final fullHeight = page.width > 0
        ? _coverWidth * page.height / page.width
        : _coverWidth * 1.414;
    final rendered = await page.render(
      fullWidth: fullWidth,
      fullHeight: fullHeight,
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
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => PdfRenderer.open(file: file, settings: settings, initialAnchor: anchor);
}
