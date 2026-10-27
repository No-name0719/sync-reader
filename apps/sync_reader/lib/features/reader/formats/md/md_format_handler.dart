/// md 格式处理器（FR-204）：结构化块解析 → 标题 TOC + 指纹；渲染器为
/// [MdRenderer]（flutter_markdown_plus 分块渲染 + headingIndex/blockIndex/
/// charOffset 精确定位）。
///
/// 解码策略：md 规范即 UTF-8——**严格 UTF-8 直读**（dart:convert，坏字节 /
/// UTF-16 内容才降级）；非 UTF-8 存量（UTF-16 BOM、GBK 等）走
/// formats/common/text_decoder.dart 的自动检测兜底（该文件由 txt 代理并行
/// 升级中，本 handler 只消费其现有公开 API）。封面无（coverBytes null，
/// 书库侧文字封面兜底）。
///
/// **接口签名即冻结 API**。
library;

import 'dart:convert';

import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_settings.dart';
import '../handler_base.dart';
import '../common/text_decoder.dart';
import 'md_block_parser.dart';
import 'md_renderer.dart';

export 'md_locator.dart' show MdHeadingAnchor;

/// md 文本读取：严格 UTF-8 直读（剥 U+FEFF 前缀）；UTF-16 BOM 或非合法
/// UTF-8 时走 [TextDecoder] 自动检测兜底。
Future<String> _readMdText(BookFile file) async {
  final bytes = await file.file.readAsBytes();
  final hasUtf16Bom =
      bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF));
  if (hasUtf16Bom) {
    return TextDecoder.decode(bytes).text;
  }
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  } on FormatException {
    return TextDecoder.decode(bytes).text;
  }
}

/// md 格式处理器。
class MdFormatHandler extends FormatHandlerBase {
  MdFormatHandler();

  @override
  String get formatId => 'md';

  @override
  Set<String> get extensions => {'md', 'markdown'};

  @override
  Future<ParsedContent> parseContent(BookFile file) async {
    final text = await _readMdText(file);
    final blocks = const MdBlockParser().parse(text);
    return ParsedContent(toc: buildTocFromBlocks(blocks));
  }

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) async {
    final text = await _readMdText(file);
    final blocks = const MdBlockParser().parse(text);
    return MdRenderer(
      blocks: blocks,
      documentLength: text.length,
      settings: settings,
      initialAnchor: anchor,
    );
  }
}
