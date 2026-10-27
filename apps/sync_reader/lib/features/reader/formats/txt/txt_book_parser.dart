/// 整书解码 + 章节切分（isolate 入口）与切分结果载体 [TxtBook]。
///
/// 100 万字中文 txt（UTF-8/GBK 均约 2–3MB）在 isolate 中解码+切章 < 1.5s
/// （FR-202 性能线）；调用方（handler/renderer）一律经由本文件
/// [TxtBook.parse]，避免在主 isolate 做大文本 CPU 工作。
library;

import 'package:flutter/foundation.dart';

import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import '../../contract/toc_fingerprint.dart';
import '../common/text_decoder.dart';
import 'txt_chapter.dart';
import 'txt_chapter_anchor.dart';
import 'txt_chapter_splitter.dart';

/// isolate 请求（纯数据，可跨 isolate 发送）。
class TxtParseRequest {
  const TxtParseRequest({required this.bytes, required this.override});

  /// 整书字节。
  final Uint8List bytes;

  /// 编码覆盖（auto = 自动探测）。
  final ReaderTextEncoding override;
}

/// isolate 结果（纯数据）。
class TxtParseResult {
  const TxtParseResult({
    required this.text,
    required this.encodingName,
    required this.chapters,
  });

  /// 解码后的全文。
  final String text;

  /// 实际编码名（'utf-8'/'gbk'/…，日志与调试展示）。
  final String encodingName;

  /// 章节表。
  final List<TxtChapter> chapters;
}

/// [compute] 的顶层入口：解码 + 切章一并做。
TxtParseResult parseTxtBook(TxtParseRequest request) {
  final decoded = TextDecoder.decode(request.bytes, override: request.override);
  final chapters = TxtChapterSplitter.split(decoded.text);
  return TxtParseResult(
    text: decoded.text,
    encodingName: decoded.encodingName,
    chapters: chapters,
  );
}

/// 一本书的解码产物：全文 + 编码名 + 章节表。
class TxtBook {
  const TxtBook._({
    required this.text,
    required this.encodingName,
    required this.chapters,
  });

  /// 解码后的全文（locator charOffset 与 percent 的坐标系）。
  final String text;

  /// 实际编码名。
  final String encodingName;

  /// 章节表（区间相接、覆盖全文；无章节命中时为单章全文）。
  final List<TxtChapter> chapters;

  /// 在 isolate 中解码 + 切章。
  static Future<TxtBook> parse(
    Uint8List bytes,
    ReaderTextEncoding override,
  ) async {
    final result = await compute(
      parseTxtBook,
      TxtParseRequest(bytes: bytes, override: override),
    );
    return TxtBook._(
      text: result.text,
      encodingName: result.encodingName,
      chapters: result.chapters,
    );
  }

  /// 全书总字符数（UTF-16 码元）。
  int get totalChars => text.length;

  /// 钳制到合法区间的章。
  TxtChapter chapterAt(int index) =>
      chapters[index.clamp(0, chapters.length - 1)];

  /// 章节表 → TOC（level 统一 0；anchor 带章起始偏移，指纹随之覆盖章序+位置）。
  List<TocEntry> buildToc() => [
    for (var i = 0; i < chapters.length; i++)
      TocEntry(
        title: chapters[i].title,
        level: 0,
        anchor: TxtChapterAnchor(
          chapterIndex: i,
          charOffset: chapters[i].startOffset,
        ),
      ),
  ];

  /// 目录指纹（parseMetadata 与跨端比对用）。
  String get tocFingerprint => TocFingerprint.compute(buildToc());
}
