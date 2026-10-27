/// TOC 构建与指纹稳定性（FR-204 + docs/05 §3.2）：标题块 → TocEntry/
/// MdHeadingAnchor 的映射，围栏内标题不进目录，指纹对结构敏感。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/md/md_block_parser.dart';
import 'package:sync_reader/features/reader/formats/md/md_format_handler.dart';

void main() {
  group('buildTocFromBlocks', () {
    test('标题块 → TocEntry（level 0 起）+ MdHeadingAnchor（序号+块首偏移）', () {
      const source = '# A\n\n## B\n\ntext\n\n### C\n';
      final blocks = const MdBlockParser().parse(source);
      final toc = buildTocFromBlocks(blocks);

      expect(toc, hasLength(3));
      expect(toc.map((e) => e.title).toList(), ['A', 'B', 'C']);
      expect(toc.map((e) => e.level).toList(), [0, 1, 2]);
      // 偏移：'# A'@0、'## B'@5（空行占两个换行符）、'### C'@17。
      expect(toc.map((e) => e.anchor).toList(), [
        const MdHeadingAnchor(headingIndex: 0, charOffset: 0),
        const MdHeadingAnchor(headingIndex: 1, charOffset: 5),
        const MdHeadingAnchor(headingIndex: 2, charOffset: 17),
      ]);
      expect(toc[1].anchor.toString(), 'md:heading:1:5');
    });

    test('围栏代码块内的 # 不产生目录条目', () {
      final blocks = const MdBlockParser().parse('# 标题\n```\n# 不是标题\n```\n');
      final toc = buildTocFromBlocks(blocks);
      expect(toc, hasLength(1));
      expect(toc.single.title, '标题');
    });

    test('无标题文档 → 空 toc（单章）', () {
      final blocks = const MdBlockParser().parse('只有段落，没有标题。\n');
      expect(buildTocFromBlocks(blocks), isEmpty);
    });

    test('Setext 标题同样进入目录', () {
      final blocks = const MdBlockParser().parse('章名\n===\n正文\n');
      final toc = buildTocFromBlocks(blocks);
      expect(toc, hasLength(1));
      expect(toc.single.title, '章名');
      expect(toc.single.level, 0);
    });
  });

  group('TocFingerprint 稳定性', () {
    final tocA = buildTocFromBlocks(
      const MdBlockParser().parse('# A\n\n## B\n'),
    );
    final tocA2 = buildTocFromBlocks(
      const MdBlockParser().parse('# A\n\n## B\n'),
    );
    final tocB = buildTocFromBlocks(
      const MdBlockParser().parse('# A\n\n## B2\n'),
    );

    test('同结构 → 同指纹（tfp: 前缀）', () {
      final f1 = TocFingerprint.compute(tocA);
      final f2 = TocFingerprint.compute(tocA2);
      expect(f1, f2);
      expect(f1, startsWith('tfp:'));
      expect(f1.length, 'tfp:'.length + 16);
    });

    test('标题文本变化 → 指纹变化', () {
      expect(TocFingerprint.compute(tocA), isNot(TocFingerprint.compute(tocB)));
    });

    test('锚点偏移变化 → 指纹变化（anchor.toString 参与序列化）', () {
      final shifted = buildTocFromBlocks(
        const MdBlockParser().parse('\n\n# A\n\n## B\n'),
      );
      expect(
        TocFingerprint.compute(tocA),
        isNot(TocFingerprint.compute(shifted)),
      );
    });

    test('空 toc 指纹仍可计算（单章文档跨端一致）', () {
      expect(TocFingerprint.compute(const []), startsWith('tfp:'));
    });
  });

  group('MdHeadingAnchor', () {
    test('toString ↔ tryParse 往返', () {
      const anchor = MdHeadingAnchor(headingIndex: 12, charOffset: 3456);
      final parsed = MdHeadingAnchor.tryParse(anchor.toString());
      expect(parsed?.headingIndex, 12);
      expect(parsed?.charOffset, 3456);
    });

    test('非法形式返回 null', () {
      expect(MdHeadingAnchor.tryParse('txt:chapter:1:0'), isNull);
      expect(MdHeadingAnchor.tryParse('md:heading:x:0'), isNull);
      expect(MdHeadingAnchor.tryParse(''), isNull);
    });
  });

  group('MdFormatHandler.parseMetadata', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sync_reader_md_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// 写样例文件并包装成 BookFile。
    Future<BookFile> writeBook(String fileName, String content) async {
      final file = File(p.join(tempDir.path, fileName));
      await file.writeAsString(content);
      final stat = await file.stat();
      return BookFile(
        path: file.path,
        fileName: fileName,
        sizeBytes: stat.size,
      );
    }

    test('标题目录 + 文件名元数据 + 指纹', () async {
      final file = await writeBook('笔记.md', '# 总览\n\n正文\n\n## 小节\n');
      final parsed = await MdFormatHandler().parseMetadata(file);
      expect(parsed.title, '笔记');
      expect(parsed.author, '');
      expect(parsed.toc, hasLength(2));
      expect(parsed.toc[0].level, 0);
      expect(parsed.toc[1].title, '小节');
      expect(parsed.tocFingerprint, startsWith('tfp:'));
      expect(parsed.coverBytes, isNull);
    });

    test('无标题文档：空 toc + 单章', () async {
      final file = await writeBook('随笔.md', '只有一段话。\n');
      final parsed = await MdFormatHandler().parseMetadata(file);
      expect(parsed.toc, isEmpty);
      expect(parsed.tocFingerprint, startsWith('tfp:'));
    });

    test('canHandle：md/markdown/大写扩展名', () {
      final handler = MdFormatHandler();
      expect(handler.formatId, 'md');
      expect(handler.canHandle('md', Uint8List(0)), isTrue);
      expect(handler.canHandle('markdown', Uint8List(0)), isTrue);
      expect(handler.canHandle('MD', Uint8List(0)), isTrue);
      expect(handler.canHandle('txt', Uint8List(0)), isFalse);
    });
  });
}
