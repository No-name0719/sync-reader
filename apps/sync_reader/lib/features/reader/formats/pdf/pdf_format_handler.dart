/// pdf 格式处理器（FR-205 / FR-102 / FR-103）：元数据解析（outline 目录 +
/// 首页封面缩略图）与渲染器创建。
///
/// 解析约定（契约，见 `FormatHandlerBase`）：**解析失败不得抛出**——
/// flutter test 环境无 pdfium.dll、损坏/加密文件等一律捕获后降级为
/// 文件名元数据 + 空目录，绝不阻塞书库导入。
///
/// 封面注入点（FR-103）：pdfrx 封面渲染经 [PdfCoverRenderer] 函数类型注入
/// （构造函数可选参数，默认 [renderPdfFirstPageCover]）。测试环境无 pdfium
/// 时注入 fake 即可覆盖封面成功/失败路径；封面渲染失败只降级为无封面，
/// 不影响 toc/元数据。
///
/// 指纹约定：有 outline 时对 toc 指纹；无 outline 时对页数指纹
/// （`pagesFingerprintEntry`），保证跨端对同一文件产出一致指纹。
library;

import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/parsed_book.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import '../../contract/toc_fingerprint.dart';
import '../common/file_name_parser.dart';
import '../handler_base.dart';
import 'pdf_cover_renderer.dart';
import 'pdf_outline_mapper.dart';
import 'pdf_renderer.dart';

export 'pdf_page_anchor.dart';

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
  /// [coverRenderer]：封面渲染注入点（测试注入 fake，生产用默认 pdfrx 实现）。
  PdfFormatHandler({PdfCoverRenderer? coverRenderer})
    : _coverRenderer = coverRenderer ?? renderPdfFirstPageCover;

  final PdfCoverRenderer _coverRenderer;

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

  /// 解析 pdf：目录/页数与封面为**两个独立降级段**——任一失败只影响
  /// 自身（目录 → 空目录；封面 → 无封面字节），本方法整体不抛出。
  ///
  /// 目录与封面解耦的原因：pdfrx 目录提取与封面渲染各自打开文档，测试
  /// 环境无 pdfium 时目录段必抛（降级空目录），但注入 fake 封面函数后
  /// 封面段仍可独立验证（FR-103 测试契约）。
  Future<_ParsedPdf> _parse(BookFile file) async {
    // 目录/页数段：pdfrx 直接解析（无 pdfium/损坏/加密 → 抛异常 → 空目录）。
    int? pageCount;
    var toc = const <TocEntry>[];
    try {
      final document = await pdfrx.PdfDocument.openFile(file.path);
      try {
        pageCount = document.pages.length;
        // 注意：pdfrx 的 FFI 有专属后台 worker，切勿将 document 调用包进 compute()。
        final outline = await document.loadOutline();
        toc = outlineItemsToTocEntries(flattenPdfOutline(outline));
      } finally {
        await document.dispose();
      }
    } catch (e, s) {
      log.warn('${file.fileName}：PDF 解析失败，降级为文件名元数据+空目录');
      log.error('PDF 解析异常详情', e, s);
    }
    // 封面段：经注入函数独立渲染（内部自开文档句柄，见 pdf_cover_renderer.dart）；
    // 失败只降级为无封面，不影响目录/元数据，也不向上抛。
    Uint8List? cover;
    try {
      cover = await _coverRenderer(file.path);
    } catch (e, s) {
      log.warn('${file.fileName}：封面渲染失败，忽略（不影响导入）');
      log.error('封面渲染异常详情', e, s);
    }
    // pdf 无可靠语言字段（Info dict 未暴露）→ language 置空。
    return _ParsedPdf(ParsedContent(coverBytes: cover, toc: toc), pageCount);
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => PdfRenderer.open(file: file, settings: settings, initialAnchor: anchor);
}
