/// 编码探测解码测试（FR-202）：BOM 三种 / GBK 中文样本 / 坏 UTF-8 /
/// 64KB 采样边界 / UTF-16 中文与代理对 / 手动覆盖（bytes 字面量构造）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/common/text_decoder.dart';

Uint8List _bytes(List<int> list) => Uint8List.fromList(list);

/// 手工构造 UTF-16LE 字节（含 BOM；emoji 走代理对）。
Uint8List _utf16leWithBom(String s) {
  final b = BytesBuilder()..add([0xFF, 0xFE]);
  for (final unit in s.codeUnits) {
    b
      ..addByte(unit & 0xFF)
      ..addByte((unit >> 8) & 0xFF);
  }
  return b.toBytes();
}

/// 手工构造 UTF-16BE 字节（含 BOM）。
Uint8List _utf16beWithBom(String s) {
  final b = BytesBuilder()..add([0xFE, 0xFF]);
  for (final unit in s.codeUnits) {
    b
      ..addByte((unit >> 8) & 0xFF)
      ..addByte(unit & 0xFF);
  }
  return b.toBytes();
}

void main() {
  group('detect() 编码检测表', () {
    test('UTF-8 BOM → utf8 / 来源=BOM', () {
      final d = TextDecoder.detect(
        _bytes([0xEF, 0xBB, 0xBF, ...utf8.encode('你好')]),
      );
      expect(d.encoding, DetectedEncoding.utf8);
      expect(d.source, TextEncodingSource.byteOrderMark);
    });

    test('UTF-16LE BOM → utf16le / 来源=BOM', () {
      final d = TextDecoder.detect(_utf16leWithBom('中文 abc'));
      expect(d.encoding, DetectedEncoding.utf16le);
      expect(d.source, TextEncodingSource.byteOrderMark);
    });

    test('UTF-16BE BOM → utf16be / 来源=BOM', () {
      final d = TextDecoder.detect(_utf16beWithBom('中文 abc'));
      expect(d.encoding, DetectedEncoding.utf16be);
      expect(d.source, TextEncodingSource.byteOrderMark);
    });

    test('无 BOM 合法 UTF-8 中文 → utf8 / 来源=启发式', () {
      final d = TextDecoder.detect(_bytes(utf8.encode('绑定到标准输出流的第一行。')));
      expect(d.encoding, DetectedEncoding.utf8);
      expect(d.source, TextEncodingSource.heuristic);
    });

    test('纯 ASCII → utf8 / 来源=启发式', () {
      final d = TextDecoder.detect(_bytes('plain ascii text 123'.codeUnits));
      expect(d.encoding, DetectedEncoding.utf8);
      expect(d.source, TextEncodingSource.heuristic);
    });

    test('GBK 中文样本 → gbk / 来源=启发式；auto 解码不乱码', () {
      const sample = '红楼梦 第一回 甄士隐梦幻识通灵，贾雨村风尘怀闺秀。';
      final bytes = Uint8List.fromList(gbk.encode(sample));
      final d = TextDecoder.detect(bytes);
      expect(d.encoding, DetectedEncoding.gbk, reason: 'GBK 字节应为启发式 GBK');
      expect(d.source, TextEncodingSource.heuristic);
      final result = TextDecoder.decode(bytes);
      expect(result.text, sample, reason: '中文 GBK 老书不乱码（FR-202 验收线）');
      expect(result.encodingName, 'gbk');
    });

    test('坏 UTF-8 但合法 GBK → gbk 兜底', () {
      // 0xC3 后须跟 0x80–0xBF 续字节，0x50 非法 → 破坏 UTF-8 合法性；
      // 而 0xC3 0x50 是合法 GBK 双字节对 → 启发式落 GBK。
      final d = TextDecoder.detect(_bytes([0xC3, 0x50, ...gbk.encode('中文测试')]));
      expect(d.encoding, DetectedEncoding.gbk);
      expect(d.source, TextEncodingSource.heuristic);
    });

    test('坏 UTF-8 且 GBK 也无法解码 → Latin1 最终兜底（不抛异常）', () {
      // 0xC3 后跟 0x28：破坏 UTF-8；GBK 双字节尾字节须 ≥ 0x40，0x28 非法 →
      // gbk.decode 抛 FormatException → 落 Latin1 防御层。
      final d = TextDecoder.detect(_bytes([0xC3, 0x28, 0x0A]));
      expect(d.encoding, DetectedEncoding.latin1);
      expect(TextDecoder.decode(_bytes([0xC3, 0x28])).text, isNotEmpty);
    });

    test('64KB 边界截断的多字节字符不误判（采样截齐）', () {
      final text = '汉' * 40000; // 120000 字节 > 64KB；65536 % 3 != 0 必截断序列
      final bytes = _bytes(utf8.encode(text));
      expect(bytes.length, greaterThan(TextDecoder.detectSampleBytes));
      final d = TextDecoder.detect(bytes);
      expect(d.encoding, DetectedEncoding.utf8, reason: '采样尾部残缺序列须裁掉');
      expect(TextDecoder.decode(bytes).text, text);
    });

    test('UTF-16LE 中文 + 代理对 emoji 解码正确', () {
      const sample = '中文abc😀尾';
      final result = TextDecoder.decode(_utf16leWithBom(sample));
      expect(result.text, sample);
      expect(result.encodingName, 'utf-16le');
    });

    test('UTF-16BE 中文 + 代理对 emoji 解码正确', () {
      const sample = '中文abc😀尾';
      final result = TextDecoder.decode(_utf16beWithBom(sample));
      expect(result.text, sample);
      expect(result.encodingName, 'utf-16be');
    });

    test('BOM 不进正文', () {
      expect(
        TextDecoder.decode(_bytes([0xEF, 0xBB, 0xBF, ...utf8.encode('你好')]))
            .text,
        '你好',
      );
      expect(TextDecoder.decode(_utf16leWithBom('你好')).text, '你好');
      expect(TextDecoder.decode(_utf16beWithBom('你好')).text, '你好');
    });

    test('空字节输入不崩溃 → 判为启发式 utf8', () {
      final d = TextDecoder.detect(Uint8List(0));
      expect(d.encoding, DetectedEncoding.utf8);
      expect(TextDecoder.decode(Uint8List(0)).text, '');
    });
  });

  group('手动覆盖 decode(override)', () {
    test('utf8 覆盖：GBK 字节按 UTF-8 强解（坏字节替换）', () {
      final gbkBytes = Uint8List.fromList(gbk.encode('中文测试'));
      final r = TextDecoder.decode(gbkBytes, override: ReaderTextEncoding.utf8);
      expect(r.encodingName, 'utf-8');
      expect(r.text.contains('\u{FFFD}'), isTrue, reason: 'GBK 字节非合法 UTF-8');
    });

    test('gbk 覆盖：UTF-8 中文按 GBK 强解（编码名 gbk）', () {
      final utf8Bytes = _bytes(utf8.encode('中文内容'));
      final r = TextDecoder.decode(utf8Bytes, override: ReaderTextEncoding.gbk);
      expect(r.encodingName, 'gbk');
      expect(r.text, isNot('中文内容'), reason: '强解产生 mojibake 属预期');
    });

    test('gbk 覆盖：GBK 中文按 GBK 解码不乱码', () {
      const sample = '射雕英雄传 第一回 风雪惊变';
      final bytes = Uint8List.fromList(gbk.encode(sample));
      expect(
        TextDecoder.decode(bytes, override: ReaderTextEncoding.gbk).text,
        sample,
      );
    });
  });

  group('decodeWith(既有结论)', () {
    test('采样结论可复用于全量解码（探测/解码分离）', () {
      const sample = '<long book> 前言 正文';
      final bytes = _bytes(utf8.encode(sample));
      final detection = TextDecoder.detect(bytes);
      final r = TextDecoder.decodeWith(bytes, detection);
      expect(r.text, sample);
      expect(r.detection, detection);
    });
  });
}
