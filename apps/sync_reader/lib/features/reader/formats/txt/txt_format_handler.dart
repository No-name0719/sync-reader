/// txt 格式处理器（FR-202）：真实章节切分 TOC + isolate 解码 + 完整渲染器。
///
/// - 元数据：书名/作者沿用基类文件名解析；TOC 来自全文行扫描切章
///   （[TxtChapterSplitter]），指纹 = [TocFingerprint.compute]。
/// - 极端大文件：切章需要全文行扫描，MB 级整读可接受；数百 MB 级
///   （> [metadataSampleThreshold]）只采样前 [metadataSampleLimit] 字节
///   做切章（TOC 覆盖采样前缀，注释说明的折衷；渲染器仍整书加载）。
/// - 渲染器：[TxtRenderer]（编码检测/覆盖、滚动+分页、locator 进度）。
library;

import 'dart:typed_data';

import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_settings.dart';
import '../handler_base.dart';
import 'txt_book_parser.dart';
import 'txt_renderer.dart';

export 'txt_chapter_anchor.dart'; // 兼容基线导入路径：锚点类型随重写迁至独立文件

/// txt 格式处理器。
class TxtFormatHandler extends FormatHandlerBase {
  /// 构造；[metadataSampleThreshold]/[metadataSampleLimit] 供测试注入小值
  /// 验证采样路径（生产用默认：>50MB 采样前 5MB）。
  TxtFormatHandler({int? metadataSampleThreshold, int? metadataSampleLimit})
    : metadataSampleThreshold =
          metadataSampleThreshold ?? _defaultSampleThreshold,
      metadataSampleLimit = metadataSampleLimit ?? _defaultSampleLimit;

  /// 超过该字节数视为极端大文件，TOC 解析只采样前缀。
  static const int _defaultSampleThreshold = 50 * 1024 * 1024;

  /// TOC 采样字节数（约数百万汉字，足够章节识别）。
  static const int _defaultSampleLimit = 5 * 1024 * 1024;

  /// 采样阈值（字节）。
  final int metadataSampleThreshold;

  /// 采样长度（字节）。
  final int metadataSampleLimit;

  @override
  String get formatId => 'txt';

  @override
  Set<String> get extensions => {'txt', 'text'};

  @override
  Future<ParsedContent> parseContent(BookFile file) async {
    final bytes = await _readBytesForMetadata(file);
    // 解码 + 切章一并放 isolate（100 万字 < 1.5s，FR-202 性能线）。
    final book = await TxtBook.parse(bytes, ReaderTextEncoding.auto);
    return ParsedContent(toc: book.buildToc());
  }

  /// 元数据用字节：常规整读；极端大文件采样前缀（见文件头注释）。
  Future<Uint8List> _readBytesForMetadata(BookFile file) async {
    if (file.sizeBytes <= metadataSampleThreshold) {
      return file.file.readAsBytes();
    }
    final raf = await file.file.open();
    try {
      final count = metadataSampleLimit < file.sizeBytes
          ? metadataSampleLimit
          : file.sizeBytes;
      return await raf.read(count);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => TxtRenderer.open(file: file, settings: settings);
}
