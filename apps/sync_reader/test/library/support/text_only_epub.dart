/// **纯文字** epub 夹具（翻页对照截图用）：单章 + 足够多的段落，**无插图**。
///
/// 与 [rich_minimal_epub] 的区别：富夹具的第一章末尾有一张插图，而插图在
/// page 模式**独占一页**且其解码是异步的 → 截「翻页中帧」时推入页可能
/// 还没画出（画面空白），无法与其它格式做同口径比对。
///
/// 纯文字夹具让翻页中帧的推入页是**文字**（与 txt 的对照帧同质）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 构建纯文字 epub 字节（单章 [paras] 段）。
Uint8List buildTextOnlyEpub({int paras = 40}) {
  final body = StringBuffer();
  for (var i = 0; i < paras; i++) {
    body.write(
      '<p>第${i + 1}段：情节持续推进，用于撑起足够的分页高度，'
      '使翻页中帧可与其它格式同口径比对。</p>',
    );
  }
  final chapter =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
      '<title>第一章</title><style>p { text-indent: 2em; }</style></head>'
      '<body><h1>第一章 起点</h1>$body</body></html>';
  final container =
      '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';
  final opf =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>纯文字夹具</dc:title><dc:creator>夹具作者</dc:creator>'
      '<dc:language>zh</dc:language>'
      '<dc:identifier id="uid">urn:uuid:test-epub-text-0001</dc:identifier>'
      '</metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'
      '</manifest>'
      '<spine toc="ncx"><itemref idref="c1"/></spine></package>';
  final ncx =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-text-0001"/></head>'
      '<docTitle><text>纯文字夹具</text></docTitle>'
      '<navMap><navPoint id="n1"><navLabel><text>第一章 起点</text></navLabel>'
      '<content src="chapter1.xhtml"/></navPoint></navMap></ncx>';

  final archive = Archive()
    ..add(ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip')))
    ..add(ArchiveFile.string('META-INF/container.xml', container))
    ..add(ArchiveFile.string('OEBPS/content.opf', opf))
    ..add(ArchiveFile.string('OEBPS/toc.ncx', ncx))
    ..add(ArchiveFile.string('OEBPS/chapter1.xhtml', chapter));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
