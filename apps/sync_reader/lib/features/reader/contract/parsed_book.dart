/// 格式解析结果（docs/03 §4.2 parseMetadata 的返回实体）。
library;

import 'dart:typed_data';

import 'toc_entry.dart';

/// 由 [BookFormatHandler.parseMetadata] 产出的书籍静态信息。
class ParsedBook {
  const ParsedBook({
    required this.title,
    required this.author,
    required this.toc,
    required this.tocFingerprint,
    this.language,
    this.coverBytes,
  });

  /// 书名（epub 取 OPF dc:title，否则文件名去扩展名）。
  final String title;

  /// 作者，无则空串。
  final String author;

  /// 目录（可为空列表，如 pdf 基线实现）。
  final List<TocEntry> toc;

  /// 目录指纹 `tfp:<16hex>`（[TocFingerprint.compute] 产出，恒非空）。
  final String tocFingerprint;

  /// ISO 639-1 语言（可空）。
  final String? language;

  /// 封面图字节（PNG/JPG，可为 null；library 层落盘到 covers/{bookId}.png）。
  final Uint8List? coverBytes;
}
