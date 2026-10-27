/// 整书解析（isolate）测试：解码 + 切章 + TOC/指纹（FR-202、docs/05 §3.2）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_book_parser.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_chapter_anchor.dart';

const _bookText =
    '第一章 风起\n'
    '内容甲。\n'
    '第二章 云涌\n'
    '内容乙。\n'
    '尾声\n'
    '完。\n';

Uint8List _bytes(List<int> list) => Uint8List.fromList(list);

void main() {
  group('TxtBook.parse（isolate：解码+切章一并）', () {
    test('UTF-8 全流程', () async {
      final book = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      expect(book.encodingName, 'utf-8');
      expect(book.text, _bookText);
      expect(book.totalChars, _bookText.length);
      expect(book.chapters.map((c) => c.title), ['第一章 风起', '第二章 云涌', '尾声']);
      expect(book.chapterAt(1).title, '第二章 云涌');
    });

    test('GBK 全流程（中文 GBK 老书不乱码）', () async {
      final bytes = Uint8List.fromList(gbk.encode(_bookText));
      final book = await TxtBook.parse(bytes, ReaderTextEncoding.auto);
      expect(book.encodingName, 'gbk');
      expect(book.text, _bookText);
    });

    test('UTF-16LE 全流程', () async {
      final b = BytesBuilder()..add([0xFF, 0xFE]);
      for (final unit in _bookText.codeUnits) {
        b
          ..addByte(unit & 0xFF)
          ..addByte((unit >> 8) & 0xFF);
      }
      final book = await TxtBook.parse(b.toBytes(), ReaderTextEncoding.auto);
      expect(book.encodingName, 'utf-16le');
      expect(book.text, _bookText);
    });

    test('编码覆盖：GBK 字节强制 utf8 → encodingName 变化', () async {
      final bytes = Uint8List.fromList(gbk.encode(_bookText));
      final book = await TxtBook.parse(bytes, ReaderTextEncoding.utf8);
      expect(book.encodingName, 'utf-8');
      expect(book.text, isNot(_bookText));
    });

    test('空文件 → 单章"正文"', () async {
      final book = await TxtBook.parse(Uint8List(0), ReaderTextEncoding.auto);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.single.title, '正文');
      expect(book.totalChars, 0);
    });
  });

  group('TOC 与指纹', () {
    test('buildToc：level 0 / anchor=章序+章首偏移', () async {
      final book = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      final toc = book.buildToc();
      expect(toc, hasLength(3));
      for (var i = 0; i < toc.length; i++) {
        expect(toc[i].level, 0);
        expect(toc[i].title, book.chapters[i].title);
        final anchor = toc[i].anchor;
        expect(anchor, isA<TxtChapterAnchor>());
        final a = anchor as TxtChapterAnchor;
        expect(a.chapterIndex, i);
        expect(a.charOffset, book.chapters[i].startOffset);
        expect(a.toString(), 'txt:chapter:$i:${book.chapters[i].startOffset}');
      }
    });

    test('指纹稳定：同文同指纹', () async {
      final a = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      final b = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      expect(a.tocFingerprint, b.tocFingerprint);
      expect(a.tocFingerprint, TocFingerprint.compute(a.buildToc()));
      expect(a.tocFingerprint, startsWith('tfp:'));
    });

    test('指纹区分：内容不同 → 指纹不同（锚点含偏移）', () async {
      final a = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      final other = _bookText.replaceFirst('内容甲。', '内容甲变了。');
      final b = await TxtBook.parse(
        _bytes(utf8.encode(other)),
        ReaderTextEncoding.auto,
      );
      expect(b.tocFingerprint, isNot(a.tocFingerprint));
    });

    test('指纹稳定：GBK 与 UTF-8 同文不同字节 → 指纹一致（解码后同文）', () async {
      final a = await TxtBook.parse(
        _bytes(utf8.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      final b = await TxtBook.parse(
        Uint8List.fromList(gbk.encode(_bookText)),
        ReaderTextEncoding.auto,
      );
      expect(a.text, b.text);
      expect(a.tocFingerprint, b.tocFingerprint, reason: '指纹锚定逻辑坐标而非物理字节');
    });
  });
}
