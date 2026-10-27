/// handler 基类：统一"文件名元数据 + 内容解析 + 失败降级 + 指纹计算"模板。
///
/// 各格式 handler 只需实现 [extensions] 与 [parseContent]；
/// [parseMetadata] 的降级约定（解析失败不得抛出）在此统一保证。
/// 后续代理整文件重写 handler 时可沿用或抛弃本基类，但
/// [BookFormatHandler] 接口签名不变。
library;

import 'package:flutter/foundation.dart';

import '../../../core/app_logger.dart';
import '../contract/book_file.dart';
import '../contract/book_format_handler.dart';
import '../contract/parsed_book.dart';
import '../contract/toc_entry.dart';
import '../contract/toc_fingerprint.dart';
import 'common/file_name_parser.dart';
import 'common/text_decoder.dart';

/// 各格式从正文内容中解析出的元数据（可空字段表示"内容由文件名兜底"）。
class ParsedContent {
  const ParsedContent({
    this.title,
    this.author,
    this.language,
    this.coverBytes,
    this.toc = const [],
  });

  /// 内容解析为空（如 pdf 基线）。
  static const ParsedContent empty = ParsedContent();

  /// 内容提供的书名（覆盖文件名解析）。
  final String? title;

  /// 内容提供的作者。
  final String? author;

  /// ISO 639-1 语言。
  final String? language;

  /// 封面字节。
  final Uint8List? coverBytes;

  /// 目录。
  final List<TocEntry> toc;
}

/// 格式处理器基类。
abstract class FormatHandlerBase implements BookFormatHandler {
  /// 模块日志器（子类共用）。
  @protected
  final AppLogger log = AppLogger();

  /// 本格式支持的扩展名集合（小写、不含点）。
  Set<String> get extensions;

  /// 解析正文内容（可抛异常；[parseMetadata] 捕获后降级）。
  Future<ParsedContent> parseContent(BookFile file);

  @override
  bool canHandle(String ext, Uint8List magicHeader) =>
      extensions.contains(ext.toLowerCase());

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async {
    final nameMeta = parseBookFileName(file.fileName);
    ParsedContent content;
    try {
      content = await parseContent(file);
    } catch (e, s) {
      log.warn('${file.fileName}：内容解析失败，降级为文件名元数据+空目录');
      log.error('解析异常详情', e, s);
      content = ParsedContent.empty;
    }
    final toc = content.toc;
    return ParsedBook(
      title: content.title ?? nameMeta.title,
      author: content.author ?? nameMeta.author,
      toc: toc,
      tocFingerprint: TocFingerprint.compute(toc),
      language: content.language,
      coverBytes: content.coverBytes,
    );
  }

  /// 便捷：整文件读字节（基线实现；大文件流式化由后续代理重写）。
  @protected
  Future<Uint8List> readBytes(BookFile file) => file.file.readAsBytes();

  /// 便捷：按 BOM → 严格 UTF-8 → GBK 探测解码读全文（txt/md 共用）。
  @protected
  Future<String> readText(BookFile file) async =>
      TextDecoder.decode(await readBytes(file)).text;
}
