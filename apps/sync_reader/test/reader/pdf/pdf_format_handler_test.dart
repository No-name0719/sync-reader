/// pdf handler 单测：canHandle 魔数判定 + parseMetadata 降级路径。
///
/// flutter test 环境无 pdfium.dll，真实打开 pdf 必然抛异常——恰好验证
/// "解析失败不得抛出、降级文件名元数据"的契约（FR-102/FR-205）。
/// 该降级对损坏文件同样成立（真机环境行为一致），测试在两种环境均稳定。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_format_handler.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_outline_mapper.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_reader_pdf_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.delete(recursive: true);
  });

  Future<BookFile> writeBookFile(String fileName, List<int> bytes) async {
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(bytes);
    return BookFile.fromPath(file.path);
  }

  group('canHandle（pdf 魔数 %PDF-）', () {
    final handler = PdfFormatHandler();

    test('扩展名 pdf（大小写不敏感）+ pdf 魔数', () {
      expect(handler.canHandle('pdf', Uint8List(0)), isTrue);
      expect(handler.canHandle('PDF', Uint8List(0)), isTrue);
      expect(handler.canHandle('pdf', utf8.encode('%PDF-1.7\n')), isTrue);
    });

    test('空魔数头部不得误判为不支持（契约）', () {
      expect(handler.canHandle('pdf', Uint8List(0)), isTrue);
    });

    test('魔数前缀不符拒绝', () {
      expect(handler.canHandle('pdf', utf8.encode('RIFF....')), isFalse);
      expect(handler.canHandle('pdf', utf8.encode('%PDFX')), isFalse);
    });

    test('其他扩展名一律拒绝', () {
      expect(handler.canHandle('txt', Uint8List(0)), isFalse);
      expect(handler.canHandle('epub', utf8.encode('%PDF-')), isFalse);
    });
  });

  group('PdfPageAnchor（锚点 toString 稳定性，指纹契约）', () {
    test('格式恒为 pdf:page:<pageIndex>:<yRatio>', () {
      expect(const PdfPageAnchor(pageIndex: 41).toString(), 'pdf:page:41:0.0');
      expect(
        const PdfPageAnchor(pageIndex: 3, yRatio: 0.5).toString(),
        'pdf:page:3:0.5',
      );
    });
  });

  group('parseMetadata 降级（无 pdfium / 损坏文件路径）', () {
    test('伪 pdf：文件名元数据 + 空 toc + 页数兜底指纹 + 无封面，不抛出', () async {
      final file = await writeBookFile(
        '设计文档 - 张三.pdf',
        utf8.encode('%PDF-1.4\n%%EOF\n'),
      );
      final parsed = await PdfFormatHandler().parseMetadata(file);

      expect(parsed.title, '设计文档'); // 文件名解析兜底
      expect(parsed.author, '张三');
      expect(parsed.toc, isEmpty);
      expect(parsed.coverBytes, isNull);
      expect(parsed.tocFingerprint, startsWith('tfp:'));
      // 降级时页数未知 → 对 pages:0 指纹（与打开成功时的 pages:N 相区分）
      expect(
        parsed.tocFingerprint,
        TocFingerprint.compute([pagesFingerprintEntry(0)]),
      );
    });

    test('空文件同样降级不抛出', () async {
      final file = await writeBookFile('broken.pdf', <int>[]);
      final parsed = await PdfFormatHandler().parseMetadata(file);
      expect(parsed.title, 'broken');
      expect(parsed.toc, isEmpty);
      expect(parsed.coverBytes, isNull);
    });

    test('无作者文件名：作者为空串', () async {
      final file = await writeBookFile(
        '算法导论.pdf',
        utf8.encode('%PDF-1.4\n%%EOF\n'),
      );
      final parsed = await PdfFormatHandler().parseMetadata(file);
      expect(parsed.title, '算法导论');
      expect(parsed.author, '');
    });
  });
}
