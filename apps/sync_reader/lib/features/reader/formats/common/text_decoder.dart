/// 文本编码探测解码（FR-202：GBK/UTF-8/UTF-16 自动检测 + 手动覆盖）。
///
/// 自动检测顺序（[TextDecoder.detect]，检测结果带来源标注可单测）：
/// 1. BOM：`EF BB BF` → UTF-8；`FF FE` → UTF-16LE；`FE FF` → UTF-16BE；
/// 2. 前 [TextDecoder.detectSampleBytes]（64KB）采样做**严格 UTF-8 试解码**
///    （采样边界按 UTF-8 序列截齐，避免把合法多字节字符误判为坏字节）；
/// 3. GBK（fast_gbk，纯 Dart，总能给出结果——中文 GBK 老书不乱码的兜底）；
/// 4. Latin1 兜底（GBK 解码实际不会失败，此层仅为防御性完备，注释说明）。
///
/// 手动覆盖：[ReaderTextEncoding.utf8]/[.gbk] 非 auto 时按指定编码整体重解码
/// （渲染器响应设置变更时调用）。
///
/// 整书解码放 isolate 由 txt 侧封装（见 formats/txt/txt_book_parser.dart）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

import '../../contract/reader_settings.dart';

/// 编码判定来源。
enum TextEncodingSource {
  /// 文件头 BOM 明示。
  byteOrderMark,

  /// 无 BOM，靠采样内容启发式推断（严格 UTF-8 试解码 / GBK 兜底）。
  heuristic,
}

/// 探测出的编码。
enum DetectedEncoding {
  /// BOM 或严格试解码命中。
  utf8,

  /// BOM `FF FE`。
  utf16le,

  /// BOM `FE FF`。
  utf16be,

  /// 中文 GBK（无 BOM 且非合法 UTF-8 时兜底；fast_gbk 解码不校验非法序列）。
  gbk,

  /// 单字节 Latin1（防御层，实际不可达：GBK 解码不会抛异常）。
  latin1,
}

/// 一次编码探测的结论：编码 + 来源标注（单测断言用）。
class EncodingDetection {
  const EncodingDetection({required this.encoding, required this.source});

  /// 判定出的编码。
  final DetectedEncoding encoding;

  /// 判定来源（BOM / 启发式）。
  final TextEncodingSource source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EncodingDetection &&
          encoding == other.encoding &&
          source == other.source;

  @override
  int get hashCode => Object.hash(encoding, source);

  @override
  String toString() => 'EncodingDetection(${encoding.name}, ${source.name})';
}

/// 解码结果：文本 + 实际使用的编码名（落日志/展示用）+ 探测结论。
class TextDecodeResult {
  const TextDecodeResult({
    required this.text,
    required this.encodingName,
    this.detection,
  });

  /// 解码后的文本。
  final String text;

  /// 实际编码名：'utf-8' / 'gbk' / 'utf-16le' / 'utf-16be' / 'iso-8859-1'。
  final String encodingName;

  /// auto 模式下的探测结论（强制覆盖时为 null）。
  final EncodingDetection? detection;
}

/// 编码探测器。
final class TextDecoder {
  TextDecoder._();

  /// 无 BOM 时的启发式采样字节数（前 64KB）。
  static const int detectSampleBytes = 64 * 1024;

  /// 按覆盖策略解码整段字节。
  ///
  /// - [ReaderTextEncoding.auto]：BOM → 64KB 采样严格 UTF-8 → GBK 依次探测，
  ///   再用探测结论解码**全部**字节；
  /// - [ReaderTextEncoding.utf8]：强制 UTF-8（坏字节替换为 U+FFFD）；
  /// - [ReaderTextEncoding.gbk]：强制 GBK。
  static TextDecodeResult decode(
    Uint8List bytes, {
    ReaderTextEncoding override = ReaderTextEncoding.auto,
  }) {
    switch (override) {
      case ReaderTextEncoding.utf8:
        return TextDecodeResult(
          text: utf8.decode(bytes, allowMalformed: true),
          encodingName: 'utf-8',
        );
      case ReaderTextEncoding.gbk:
        // fast_gbk 对非法序列抛 FormatException（如损坏文件）：强解失败时
        // 以 Latin1 兜底产出可显示文本，保证解码路径永不抛出。
        try {
          return TextDecodeResult(text: gbk.decode(bytes), encodingName: 'gbk');
        } on FormatException {
          return TextDecodeResult(
            text: latin1.decode(bytes),
            encodingName: 'gbk',
          );
        }
      case ReaderTextEncoding.auto:
        final detection = detect(bytes);
        return decodeWith(bytes, detection);
    }
  }

  /// 对采样做编码探测（不解码，纯判定，可单测）。
  ///
  /// [bytes] 任意长度；内部只取头部（BOM 看前 4 字节，启发式看前
  /// [detectSampleBytes] 字节）。
  static EncodingDetection detect(Uint8List bytes) {
    // 1. BOM 优先（UTF-16 中文电子书不少见；BOM 结论直接采信）。
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return const EncodingDetection(
        encoding: DetectedEncoding.utf8,
        source: TextEncodingSource.byteOrderMark,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return const EncodingDetection(
        encoding: DetectedEncoding.utf16le,
        source: TextEncodingSource.byteOrderMark,
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return const EncodingDetection(
        encoding: DetectedEncoding.utf16be,
        source: TextEncodingSource.byteOrderMark,
      );
    }
    // 2. 无 BOM：取前 64KB 采样。
    //   - UTF-8 试解码用"尾部截齐到序列边界"的采样（采样在多字节字符中间
    //     被截断会产生假"坏字节"）；
    //   - GBK/Latin1 试解码用原始采样（截齐会按 UTF-8 结构丢尾字节，
    //     破坏 GBK 双字节配对）。
    final head = bytes.length <= detectSampleBytes
        ? bytes
        : Uint8List.sublistView(bytes, 0, detectSampleBytes);
    final utf8Sample = _trimTrailingPartialUtf8(head);
    var malformed = false;
    try {
      final decoded = utf8.decode(utf8Sample, allowMalformed: true);
      malformed = decoded.contains('\u{FFFD}');
    } on FormatException {
      malformed = true;
    }
    if (!malformed) {
      return const EncodingDetection(
        encoding: DetectedEncoding.utf8,
        source: TextEncodingSource.heuristic,
      );
    }
    // 3. GBK 兜底（fast_gbk 不校验非法序列，总能给出结果）。
    // 4. Latin1 为防御性最终兜底：gbk.decode 遇到无法配对的序列会抛异常
    //    （如损坏文件），此时落 Latin1 产出可显示文本，对齐
    //    "GBK → Latin1"的降序约定。
    try {
      gbk.decode(head);
      return const EncodingDetection(
        encoding: DetectedEncoding.gbk,
        source: TextEncodingSource.heuristic,
      );
    } on FormatException {
      return const EncodingDetection(
        encoding: DetectedEncoding.latin1,
        source: TextEncodingSource.heuristic,
      );
    }
  }

  /// 把采样尾部截齐到 UTF-8 序列边界（任意长度样本生效）。
  static Uint8List _trimTrailingPartialUtf8(Uint8List bytes) {
    var end = bytes.length;
    // 向前最多看 3 字节找前导字节（UTF-8 序列最长 4 字节）。
    for (var back = 0; back < 4 && end - 1 - back >= 0; back++) {
      final byte = bytes[end - 1 - back];
      if (byte & 0xC0 != 0x80) {
        // 前导字节：据此推算序列应有长度，残缺则裁掉。
        final expected = _utf8SequenceLength(byte);
        if (expected > back + 1) end -= back + 1;
        break;
      }
    }
    return Uint8List.sublistView(bytes, 0, end);
  }

  /// 用既有探测结论解码全部字节（探测与解码分离，便于 isolate 分段复用）。
  static TextDecodeResult decodeWith(
    Uint8List bytes,
    EncodingDetection detection,
  ) {
    switch (detection.encoding) {
      case DetectedEncoding.utf8:
        return TextDecodeResult(
          text: utf8.decode(_skipUtf8Bom(bytes), allowMalformed: true),
          encodingName: 'utf-8',
          detection: detection,
        );
      case DetectedEncoding.utf16le:
        return TextDecodeResult(
          text: decodeUtf16(_skipBom(bytes, 2), littleEndian: true),
          encodingName: 'utf-16le',
          detection: detection,
        );
      case DetectedEncoding.utf16be:
        return TextDecodeResult(
          text: decodeUtf16(_skipBom(bytes, 2), littleEndian: false),
          encodingName: 'utf-16be',
          detection: detection,
        );
      case DetectedEncoding.gbk:
        return TextDecodeResult(
          text: gbk.decode(bytes),
          encodingName: 'gbk',
          detection: detection,
        );
      case DetectedEncoding.latin1:
        return TextDecodeResult(
          text: latin1.decode(bytes),
          encodingName: 'iso-8859-1',
          detection: detection,
        );
    }
  }

  /// UTF-8 前导字节对应的序列总长（非法前导按 1 处理）。
  static int _utf8SequenceLength(int leadByte) {
    if (leadByte & 0x80 == 0) return 1;
    if (leadByte & 0xE0 == 0xC0) return 2;
    if (leadByte & 0xF0 == 0xE0) return 3;
    if (leadByte & 0xF8 == 0xF0) return 4;
    return 1;
  }

  static Uint8List _skipBom(Uint8List bytes, int bomLength) =>
      bytes.length >= bomLength
      ? Uint8List.sublistView(bytes, bomLength)
      : bytes;

  /// 仅在字节头真的是 UTF-8 BOM 时剥除（启发式判定无 BOM，不能盲剥）。
  static Uint8List _skipUtf8Bom(Uint8List bytes) =>
      (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF)
      ? Uint8List.sublistView(bytes, 3)
      : bytes;

  /// 手写 UTF-16 解码（dart:convert 无 utf16 codec；正确配对代理对）。
  static String decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    final buffer = StringBuffer();
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final unit = littleEndian
          ? (bytes[i] | (bytes[i + 1] << 8))
          : ((bytes[i] << 8) | bytes[i + 1]);
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 3 < bytes.length) {
        // 高代理：尝试与下一个单元配成补充平面字符。
        final next = littleEndian
            ? (bytes[i + 2] | (bytes[i + 3] << 8))
            : ((bytes[i + 2] << 8) | bytes[i + 3]);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          buffer.writeCharCode(
            0x10000 + ((unit - 0xD800) << 10) + (next - 0xDC00),
          );
          i += 2;
          continue;
        }
      }
      // 孤立代理/基本平面字符原样写入（保序不丢字节）。
      buffer.writeCharCode(unit);
    }
    return buffer.toString();
  }
}
