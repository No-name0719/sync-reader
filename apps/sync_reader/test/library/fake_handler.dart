/// 测试用假格式 handler：替身实现 [BookFormatHandler]，
/// 让书库/详情页测试不依赖真实 handler（真实 handler 由其他代理并行重写）。
library;

import 'dart:typed_data';

import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';

/// 1x1 PNG（最小合法图字节，用于封面落盘验证）。
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

/// 固定输出的假 handler。
class FakeHandler implements BookFormatHandler {
  FakeHandler({
    this.formatId = 'txt',
    this.title = '解析书名',
    this.author = '作者甲',
    this.toc = const [TocEntry(title: '第一章', level: 0, anchor: 0)],
    this.coverBytes,
    Set<String>? extensions,
  }) : extensions = extensions ?? const {'txt', 'epub', 'md', 'pdf'};

  @override
  final String formatId;

  /// parseMetadata 固定返回的书名。
  final String title;

  /// parseMetadata 固定返回的作者。
  final String author;

  /// parseMetadata 固定返回的目录。
  final List<TocEntry> toc;

  /// parseMetadata 固定返回的封面字节。
  final Uint8List? coverBytes;

  /// 支持的扩展名集合。
  final Set<String> extensions;

  @override
  bool canHandle(String ext, Uint8List magicHeader) =>
      extensions.contains(ext.toLowerCase());

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async => ParsedBook(
    title: title,
    author: author,
    toc: toc,
    tocFingerprint: 'tfp:0123456789abcdef',
    coverBytes: coverBytes,
  );

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) => throw UnimplementedError();
}
