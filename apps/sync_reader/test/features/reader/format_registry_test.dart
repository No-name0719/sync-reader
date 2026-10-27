/// 契约冒烟测试：FormatRegistry 注册齐全 + 四个 handler 对最小样例文件
/// parseMetadata 不抛异常且字段正确（FR-102 / docs/03 §4.2）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/formats/common/text_decoder.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/md/md_format_handler.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';
import 'package:sync_reader/features/reader/stub_renderer.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sync_reader_fmt_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.delete(recursive: true);
  });

  /// 写样例文件并包装成 BookFile。
  Future<BookFile> writeBookFile(String fileName, List<int> bytes) async {
    final file = File(p.join(tempDir.path, fileName));
    await file.writeAsBytes(bytes);
    return BookFile.fromPath(file.path);
  }

  FormatRegistry buildRegistry() => FormatRegistry()
    ..register(TxtFormatHandler())
    ..register(MdFormatHandler())
    ..register(PdfFormatHandler())
    ..register(EpubFormatHandler());

  group('FormatRegistry', () {
    test('注册齐全且可按 formatId / 扩展名查找', () {
      final registry = buildRegistry();
      expect(registry.handlers.map((h) => h.formatId).toSet(), {
        'txt',
        'md',
        'pdf',
        'epub',
      });
      expect(registry.byFormatId('txt'), isA<TxtFormatHandler>());
      expect(registry.byExtension('epub'), isA<EpubFormatHandler>());
      expect(registry.byExtension('PDF'), isA<PdfFormatHandler>());
      expect(registry.byExtension('mobi'), isNull);
      // canHandle 大小写不敏感；空 magicHeader 不影响判定。
      expect(
        registry.byFormatId('txt')!.canHandle('TXT', Uint8List(0)),
        isTrue,
      );
      // 同 formatId 重复注册 = 覆盖。
      final registry2 = FormatRegistry()
        ..register(TxtFormatHandler())
        ..register(TxtFormatHandler());
      expect(registry2.handlers, hasLength(1));
    });
  });

  group('txt handler', () {
    test('UTF-8 文件：文件名元数据 + "第X章"切章 + 指纹', () async {
      const content =
          '第一章 起点\n开头的内容\n第二章 转折\n'
          '中间的内容\n第10章 数字章节\n结尾';
      final file = await writeBookFile('三体 - 刘慈欣.txt', utf8.encode(content));
      final parsed = await TxtFormatHandler().parseMetadata(file);

      expect(parsed.title, '三体');
      expect(parsed.author, '刘慈欣');
      expect(parsed.toc, hasLength(3));
      expect(parsed.toc[0].title, '第一章 起点');
      expect(parsed.toc[2].title, '第10章 数字章节');
      expect(parsed.tocFingerprint, startsWith('tfp:'));
      expect(parsed.tocFingerprint.length, 'tfp:'.length + 16);
      // 指纹可由公共工具复算（各 handler 复用同一算法）。
      expect(parsed.tocFingerprint, TocFingerprint.compute(parsed.toc));

      // createRenderer 契约冒烟（真实渲染器，FR-202）。
      final renderer = await TxtFormatHandler().createRenderer(
        file,
        ReaderSettings.defaults,
        ProgressAnchor.empty,
      );
      expect(renderer, isA<TxtRenderer>());
      renderer.dispose();
    });

    test('GBK 文件自动探测解码（严格 UTF-8 失败后回落）', () async {
      final gbkBytes = gbk.encode('第一章 天命\n内容');
      final file = await writeBookFile('古书.txt', gbkBytes);
      final parsed = await TxtFormatHandler().parseMetadata(file);
      expect(parsed.toc, hasLength(1));
      expect(parsed.toc.single.title, '第一章 天命');
    });

    test('无章节文件：单章"正文"目录 + 文件名元数据，不抛异常', () async {
      final file = await writeBookFile('随笔.txt', utf8.encode('只有一段话'));
      final parsed = await TxtFormatHandler().parseMetadata(file);
      expect(parsed.title, '随笔');
      expect(parsed.author, '');
      // 整书无章节命中 → 单章全文（章题"正文"），目录恒非空。
      expect(parsed.toc, hasLength(1));
      expect(parsed.toc.single.title, '正文');
      expect(parsed.tocFingerprint, startsWith('tfp:'));
    });

    test('任意字节不会让 parseMetadata 抛出（降级约定）', () async {
      final file = await writeBookFile('坏书.txt', [0x00, 0xFF, 0xFE, 0x81]);
      final parsed = await TxtFormatHandler().parseMetadata(file);
      expect(parsed.title, '坏书');
    });
  });

  group('md handler', () {
    test('标题行提取 toc（层级正确）+ 指纹', () async {
      const content = '# 一级\n正文\n## 二级 A\n更多\n### 三级\n## 二级 B\n';
      final file = await writeBookFile('笔记.md', utf8.encode(content));
      final parsed = await MdFormatHandler().parseMetadata(file);

      expect(parsed.title, '笔记');
      expect(parsed.toc, hasLength(4));
      expect(parsed.toc[0].level, 0);
      expect(parsed.toc[1].level, 1);
      expect(parsed.toc[2].level, 2);
      expect(parsed.toc[1].title, '二级 A');
      expect(parsed.tocFingerprint, startsWith('tfp:'));
    });

    test('结构化解析：围栏代码块内的 # 不进目录', () async {
      // md 阅读器代理已改为结构化块解析，围栏内的 # 行不再误判为标题。
      const content = '# 标题\n```\n# 不是标题\n```\n';
      final file = await writeBookFile('demo.md', utf8.encode(content));
      final parsed = await MdFormatHandler().parseMetadata(file);
      expect(parsed.toc, hasLength(1));
      expect(parsed.toc.single.title, '标题');
    });
  });

  group('pdf handler', () {
    test('最小 PDF 头：文件名元数据 + 空 toc', () async {
      final file = await writeBookFile(
        '设计文档.pdf',
        utf8.encode('%PDF-1.4\n%%EOF\n'),
      );
      final handler = PdfFormatHandler();
      final parsed = await handler.parseMetadata(file);
      expect(parsed.title, '设计文档');
      expect(parsed.toc, isEmpty);
      expect(parsed.coverBytes, isNull);
      expect(parsed.tocFingerprint, startsWith('tfp:'));

      // createRenderer 冒烟：真实 handler 会经 pdfrx 打开文件；测试环境无
      // pdfium.dll（且样例也非合法 PDF），两种环境下打开该样例都必然失败，
      // 错误应向宿主抛出而非静默（ReaderPage 据此展示错误页，FR-205）。
      await expectLater(
        handler.createRenderer(
          file,
          ReaderSettings.defaults,
          ProgressAnchor.empty,
        ),
        throwsA(anything),
      );
    });
  });

  group('epub handler（完整基线）', () {
    test('最简 epub：OPF 元数据 + 封面 + spine 序 toc + 指纹', () async {
      final file = await writeBookFile('测试书 - 测试作者.epub', buildMinimalEpub());
      final parsed = await EpubFormatHandler().parseMetadata(file);

      expect(parsed.title, '测试书');
      expect(parsed.author, '测试作者');
      expect(parsed.language, 'zh');
      expect(parsed.coverBytes, isNotNull);
      expect(parsed.toc, hasLength(2)); // spine 序：ch1 → ch2
      expect(parsed.toc[0].title, '第一章');
      expect(parsed.toc[1].title, '第二章');
      expect(parsed.tocFingerprint, startsWith('tfp:'));
      expect(parsed.tocFingerprint, TocFingerprint.compute(parsed.toc));

      // 锚点 toString 稳定性（指纹契约的一部分）。
      expect(parsed.toc[0].anchor.toString(), 'epub:spine:0:chapter1.xhtml');

      // epub 渲染器仍未实现（M1 后续里程碑），基线占位是当前正确行为。
      final renderer = await EpubFormatHandler().createRenderer(
        file,
        ReaderSettings.defaults,
        ProgressAnchor.empty,
      );
      expect(renderer, isA<StubRenderer>());
      renderer.dispose();
    });

    test('损坏的 epub 降级为文件名元数据，不抛异常', () async {
      final file = await writeBookFile('残书 - 佚名.epub', [0, 1, 2, 3]);
      final parsed = await EpubFormatHandler().parseMetadata(file);
      expect(parsed.title, '残书');
      expect(parsed.author, '佚名');
      expect(parsed.toc, isEmpty);
    });
  });

  group('TocFingerprint', () {
    test('空目录指纹稳定；结构变化 → 指纹变化', () {
      expect(
        TocFingerprint.compute(const []),
        TocFingerprint.compute(const []),
      );

      final a = TocFingerprint.compute(const [
        TocEntry(title: '一', level: 0, anchor: 'txt:chapter:0:0'),
      ]);
      final b = TocFingerprint.compute(const [
        TocEntry(title: '一', level: 0, anchor: 'txt:chapter:0:1'),
      ]);
      expect(a, isNot(b)); // 锚点参与指纹（防跳错章节的关键）。
      final c = TocFingerprint.compute(const [
        TocEntry(title: '一', level: 0, anchor: 'txt:chapter:0:0'),
        TocEntry(title: '二', level: 0, anchor: 'txt:chapter:1:0'),
      ]);
      expect(a, isNot(c));
    });
  });

  group('TextDecoder（编码探测）', () {
    test('BOM → 严格 UTF-8 → GBK 降序', () {
      final bomResult = TextDecoder.decode(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('你好')]),
      );
      expect(bomResult.encodingName, 'utf-8');
      expect(bomResult.text, '你好');

      expect(TextDecoder.decode(utf8.encode('普通文本')).encodingName, 'utf-8');

      final gbkResult = TextDecoder.decode(
        Uint8List.fromList(gbk.encode('中文GBK')),
      );
      expect(gbkResult.encodingName, 'gbk');
      expect(gbkResult.text, '中文GBK');

      // 强制覆盖。
      expect(
        TextDecoder.decode(
          utf8.encode('A'),
          override: ReaderTextEncoding.gbk,
        ).encodingName,
        'gbk',
      );
      expect(
        TextDecoder.decode(
          Uint8List.fromList(gbk.encode('强制')),
          override: ReaderTextEncoding.utf8,
        ).text,
        isNotEmpty,
      );
    });
  });
}

/// 构造最简合法 epub（mimetype + container.xml + OPF + NCX + 两个 spine 文件 + 封面）。
Uint8List buildMinimalEpub() {
  final encoder = ZipEncoder();
  final archive = Archive();

  void addFile(String name, List<int> data) {
    archive.addFile(
      ArchiveFile(name, data.length, Uint8List.fromList(data))
        ..compression = (name == 'mimetype'
            ? CompressionType.none
            : CompressionType.deflate),
    );
  }

  addFile('mimetype', utf8.encode('application/epub+zip'));
  addFile(
    'META-INF/container.xml',
    utf8.encode('''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
  );
  addFile(
    'OEBPS/content.opf',
    utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>测试书</dc:title>
    <dc:creator opf:role="aut">测试作者</dc:creator>
    <dc:language>zh</dc:language>
    <dc:identifier id="uid">urn:uuid:test-book</dc:identifier>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>'''),
  );
  addFile(
    'OEBPS/toc.ncx',
    utf8.encode('''<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:test-book"/></head>
  <docTitle><text>测试书</text></docTitle>
  <navMap>
    <navPoint id="n1" playOrder="1"><navLabel><text>第一章</text></navLabel>
      <content src="chapter1.xhtml"/></navPoint>
    <navPoint id="n2" playOrder="2"><navLabel><text>第二章</text></navLabel>
      <content src="chapter2.xhtml"/></navPoint>
  </navMap>
</ncx>'''),
  );
  addFile('OEBPS/cover.jpg', [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xD9]);
  addFile(
    'OEBPS/chapter1.xhtml',
    utf8.encode('<html><body><h1>第一章</h1><p>内容一</p></body></html>'),
  );
  addFile(
    'OEBPS/chapter2.xhtml',
    utf8.encode('<html><body><h1>第二章</h1><p>内容二</p></body></html>'),
  );

  return Uint8List.fromList(encoder.encode(archive));
}
