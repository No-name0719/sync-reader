/// TxtFormatHandler 测试（FR-102/FR-202）：canHandle 表、真实切章 TOC、
/// 指纹、空文件、解析失败降级、极端大文件采样、createRenderer 冒烟。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';

const _bookText =
    '第一章 风起\n内容甲。\n'
    '第二章 云涌\n内容乙。\n'
    '第三章 归途\n内容丙。\n';

Future<BookFile> _writeBook(
  Uint8List bytes, {
  String fileName = '凡人修仙传 - 忘语.txt',
}) async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_handler');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(bytes);
  return BookFile.fromPath(file.path);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('canHandle', () {
    final handler = TxtFormatHandler();
    test('扩展名表：txt/text 大小写；空魔数不误判', () {
      expect(handler.canHandle('txt', Uint8List(0)), isTrue);
      expect(handler.canHandle('TXT', Uint8List(0)), isTrue);
      expect(handler.canHandle('text', Uint8List(0)), isTrue);
      expect(handler.canHandle('md', Uint8List(0)), isFalse);
      expect(handler.canHandle('epub', Uint8List(0)), isFalse);
    });
    test('formatId', () => expect(handler.formatId, 'txt'));
  });

  group('parseMetadata', () {
    test('UTF-8 三章书：文件名元数据 + 真实切章 TOC + 指纹', () async {
      final bf = await _writeBook(Uint8List.fromList(utf8.encode(_bookText)));
      final parsed = await TxtFormatHandler().parseMetadata(bf);
      expect(parsed.title, '凡人修仙传');
      expect(parsed.author, '忘语');
      expect(parsed.toc, hasLength(3));
      expect(parsed.toc.map((e) => e.title), ['第一章 风起', '第二章 云涌', '第三章 归途']);
      for (var i = 0; i < parsed.toc.length; i++) {
        expect(parsed.toc[i].level, 0);
        final anchor = parsed.toc[i].anchor as TxtChapterAnchor;
        expect(anchor.chapterIndex, i);
        expect(anchor.charOffset, _bookText.indexOf('第${['一', '二', '三'][i]}章'));
      }
      expect(parsed.tocFingerprint, TocFingerprint.compute(parsed.toc));
      expect(parsed.tocFingerprint, startsWith('tfp:'));
    });

    test('GBK 书：中文不乱码，TOC 正确', () async {
      final bf = await _writeBook(
        Uint8List.fromList(gbk.encode(_bookText)),
        fileName: '射雕英雄传 - 金庸.txt',
      );
      final parsed = await TxtFormatHandler().parseMetadata(bf);
      expect(parsed.toc, hasLength(3));
      expect(parsed.toc.first.title, '第一章 风起');
      expect(parsed.title, '射雕英雄传');
      expect(parsed.author, '金庸');
    });

    test('无章节文本 → 单章 TOC', () async {
      final bf = await _writeBook(
        Uint8List.fromList(utf8.encode('没有章节的文字。\n再来一段。')),
      );
      final parsed = await TxtFormatHandler().parseMetadata(bf);
      expect(parsed.toc, hasLength(1));
      expect(parsed.toc.single.title, '正文');
    });

    test('空文件 → 单章空 TOC，不抛异常', () async {
      final bf = await _writeBook(Uint8List(0), fileName: '空书.txt');
      final parsed = await TxtFormatHandler().parseMetadata(bf);
      expect(parsed.toc, hasLength(1));
      expect(parsed.title, '空书');
    });

    test('解析失败（文件缺失）→ 降级文件名元数据 + 空目录，不抛异常', () async {
      final bf = BookFile(
        path:
            '${Directory.systemTemp.path}${Platform.pathSeparator}不存在_${DateTime.now().microsecondsSinceEpoch}.txt',
        fileName: '降级书 - 某作者.txt',
        sizeBytes: 0,
      );
      final parsed = await TxtFormatHandler().parseMetadata(bf);
      expect(parsed.title, '降级书');
      expect(parsed.author, '某作者');
      expect(parsed.toc, isEmpty);
      expect(parsed.tocFingerprint, TocFingerprint.compute(const []));
    });

    test('极端大文件采样：只扫描采样前缀（阈值/上限注入）', () async {
      // 全文 300+ 字节；标题藏在偏移 > 采样上限处 → 采样 TOC 不含它。
      final text = '${'字' * 300}\n第二章 藏在深处\n内容\n';
      final bf = await _writeBook(Uint8List.fromList(utf8.encode(text)));
      final handler = TxtFormatHandler(
        metadataSampleThreshold: 16,
        metadataSampleLimit: 64,
      );
      final parsed = await handler.parseMetadata(bf);
      expect(parsed.toc, hasLength(1), reason: '采样窗口内无章回标题 → 单章');
      expect(parsed.toc.single.title, '正文');

      // 标题落在采样窗口内 → 命中。
      final text2 = '第一章 在窗口内\n${'字' * 300}\n';
      final bf2 = await _writeBook(Uint8List.fromList(utf8.encode(text2)));
      final parsed2 = await TxtFormatHandler(
        metadataSampleThreshold: 16,
        metadataSampleLimit: 64,
      ).parseMetadata(bf2);
      expect(parsed2.toc.map((e) => e.title), ['第一章 在窗口内']);
    });
  });

  group('createRenderer', () {
    test('返回 TxtRenderer，restore/jumpTo 可用', () async {
      final bf = await _writeBook(Uint8List.fromList(utf8.encode(_bookText)));
      final renderer = await TxtFormatHandler().createRenderer(
        bf,
        ReaderSettings.defaults,
        ProgressAnchor.empty,
      );
      expect(renderer, isA<TxtRenderer>());
      final result = await renderer.controller.restore(
        ProgressAnchor(
          locatorJson: '{"type":"txt","chapterIndex":2,"charOffset":0}',
          percent: 0.9,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.exact);
      expect(renderer.controller.percent, greaterThan(0.5));
      renderer.dispose();
    });
  });
}
