/// 最小 epub 测试夹具（与 testdata/gen_samples.py 的 book-sample.epub 同构）：
/// OPF 元数据 + `<meta name="cover">` 封面声明 + 单章正文。
///
/// 用 archive 包在测试内即时构建（不依赖仓库外文件路径），封面字节由调用方
/// 注入（通常用 fake_handler.dart 的 tinyPng）。元数据正文均为 UTF-8。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 构建最小 epub 字节。
Uint8List buildMinimalEpub({required List<int> coverBytes}) {
  final container =
      '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';
  final opf =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>夹具书名</dc:title><dc:creator>夹具作者</dc:creator>'
      '<dc:language>zh</dc:language>'
      '<dc:identifier id="uid">urn:uuid:test-epub-0001</dc:identifier>'
      '<meta name="cover" content="cover-image"/></metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="cover-image" href="cover.png" media-type="image/png"/></manifest>'
      '<spine toc="ncx"><itemref idref="c1"/></spine></package>';
  final ncx =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-0001"/></head>'
      '<docTitle><text>夹具书名</text></docTitle>'
      '<navMap><navPoint id="n1"><navLabel><text>第一章</text></navLabel>'
      '<content src="chapter1.xhtml"/></navPoint></navMap></ncx>';
  final chapter =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title>'
      '</head><body><h1>第一章</h1><p>夹具正文段落。</p></body></html>';

  final archive = Archive()
    ..add(ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip')))
    ..add(ArchiveFile.string('META-INF/container.xml', container))
    ..add(ArchiveFile.string('OEBPS/content.opf', opf))
    ..add(ArchiveFile.string('OEBPS/toc.ncx', ncx))
    ..add(ArchiveFile.string('OEBPS/chapter1.xhtml', chapter))
    ..add(ArchiveFile.bytes('OEBPS/cover.png', coverBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
