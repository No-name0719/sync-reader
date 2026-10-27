/// 富内容 epub 测试夹具（渲染器测试用）：两章 + h1/h2 + p（粗/斜体）+
/// blockquote + ul/li + img（引用 tinyPng，跨目录）+ hr；第二章为独立
/// 内容文件（跨文件 spine），并带足量长段落撑起滚动。
///
/// 用 archive 包在测试内即时构建；不改既有 buildMinimalEpub（单章最小夹具）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 第一章内容：富排版元素样例（与渲染断言的可见文本一一对应）。
const String richChapter1 =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
    '<title>第一章</title><style>p { text-indent: 2em; }</style></head>'
    '<body>'
    '<h1>第一章 起点</h1>'
    '<p>开篇段落，含<strong>加粗文本</strong>与<em>斜体文本</em>。</p>'
    '<blockquote><p>引用名言一段。</p></blockquote>'
    '<ul><li>列表条目甲</li><li>列表条目乙</li></ul>'
    '<p><img src="images/pic.png" alt="插图"/></p>'
    '<hr/>'
    '<p>第一章收尾段落。</p>'
    '</body></html>';

/// 第二章内容：h2 标题 + [paras] 个长段落（撑起滚动/翻页）。
String buildRichChapter2({int paras = 40}) {
  final body = StringBuffer();
  for (var i = 0; i < paras; i++) {
    body.write(
      '<p>第二章的第$i段：情节持续推进，用于撑起足够的滚动高度，'
      '使滚动定位、翻页与进度恢复均可测。</p>',
    );
  }
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
      '<title>第二章</title></head><body>'
      '<h2>第二章 转折</h2>$body</body></html>';
}

/// 构建富内容 epub 字节。
///
/// [coverBytes] 注入封面（通常用 fake_handler.dart 的 tinyPng），
/// 同一字节也作为正文插图 OEBPS/images/pic.png 的内容。
Uint8List buildRichMinimalEpub({
  required List<int> coverBytes,
  int paras = 40,
}) {
  final container =
      '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';
  final opf =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>富夹具书名</dc:title><dc:creator>夹具作者</dc:creator>'
      '<dc:language>zh</dc:language>'
      '<dc:identifier id="uid">urn:uuid:test-epub-rich-0001</dc:identifier>'
      '<meta name="cover" content="cover-image"/></metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="cover-image" href="cover.png" media-type="image/png"/>'
      '<item id="pic" href="images/pic.png" media-type="image/png"/></manifest>'
      '<spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine></package>';
  final ncx =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-rich-0001"/></head>'
      '<docTitle><text>富夹具书名</text></docTitle>'
      '<navMap>'
      '<navPoint id="n1"><navLabel><text>第一章 起点</text></navLabel>'
      '<content src="chapter1.xhtml"/></navPoint>'
      '<navPoint id="n2"><navLabel><text>第二章 转折</text></navLabel>'
      '<content src="chapter2.xhtml"/></navPoint>'
      '</navMap></ncx>';

  final archive = Archive()
    ..add(ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip')))
    ..add(ArchiveFile.string('META-INF/container.xml', container))
    ..add(ArchiveFile.string('OEBPS/content.opf', opf))
    ..add(ArchiveFile.string('OEBPS/toc.ncx', ncx))
    ..add(ArchiveFile.string('OEBPS/chapter1.xhtml', richChapter1))
    ..add(
      ArchiveFile.string(
        'OEBPS/chapter2.xhtml',
        buildRichChapter2(paras: paras),
      ),
    )
    ..add(ArchiveFile.bytes('OEBPS/cover.png', coverBytes))
    ..add(ArchiveFile.bytes('OEBPS/images/pic.png', coverBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
