/// 「字符密度与像素密度悬殊」的 epub 测试夹具（目录跳转收敛用）。
///
/// 场景：第一章是**长段落**（每段折两行，字符密度高）、第二章是**插图章**
/// （每张插图在 page 模式独占一整页，几乎没有字符，字符密度极低）、第三章是
/// 大量短段落。
///
/// 用途：目录跳转的「粗跳估计」若按**全书字符比例**换算偏移，会被第一章的
/// 高字符密度带偏（估计值落到目标之后一屏开外 → 目标块构建不出来 → 定位
/// 收敛不了 → **跳转落到别的章**）。按**已构建区的块序号外推**才能落准。
///
/// 构造方式与 rich_minimal_epub.dart 一致：在测试内即时打包，不改既有夹具。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// 构建密度悬殊的 epub 字节。
///
/// [picBytes]：插图字节（正文插图的内容）。
Uint8List buildDensitySkewEpub({required List<int> picBytes}) {
  final container =
      '<?xml version="1.0"?><container version="1.0" '
      'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/></rootfiles></container>';
  final opf =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="uid" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>密度悬殊书</dc:title><dc:creator>夹具作者</dc:creator>'
      '<dc:language>zh</dc:language>'
      '<dc:identifier id="uid">urn:uuid:test-epub-density-skew-0001</dc:identifier>'
      '</metadata>'
      '<manifest>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '<item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="c3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="pic" href="images/pic.png" media-type="image/png"/></manifest>'
      '<spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/>'
      '<itemref idref="c3"/></spine></package>';
  final ncx =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<head><meta name="dtb:uid" content="urn:uuid:test-epub-density-skew-0001"/>'
      '</head>'
      '<docTitle><text>密度悬殊书</text></docTitle><navMap>'
      '<navPoint id="n1"><navLabel><text>第一章 长文</text></navLabel>'
      '<content src="chapter1.xhtml"/></navPoint>'
      '<navPoint id="n2"><navLabel><text>第二章 插图</text></navLabel>'
      '<content src="chapter2.xhtml"/></navPoint>'
      '<navPoint id="n3"><navLabel><text>第三章 短文</text></navLabel>'
      '<content src="chapter3.xhtml"/></navPoint>'
      '</navMap></ncx>';

  // 第一章：长段落（折两行，字符密度高）。
  final c1 = StringBuffer(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>'
    '<body><h1>第一章 长文</h1>',
  );
  for (var i = 0; i < 40; i++) {
    c1.write(
      '<p>第一章第$i段：这里是刻意写得很长很长的一段正文内容，需要折成两行'
      '才能放得下，用来制造字符密度与像素密度的不一致。</p>',
    );
  }
  c1.write('</body></html>');

  // 第二章：插图章（page 模式每张插图独占一整页，字符密度极低）。
  final c2 = StringBuffer(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head>'
    '<body><h2>第二章 插图</h2>',
  );
  for (var i = 0; i < 3; i++) {
    c2.write('<p><img src="images/pic.png" alt="插图"/></p>');
  }
  for (var i = 0; i < 2; i++) {
    c2.write('<p>第二章第$i段。</p>');
  }
  c2.write('</body></html>');

  // 第三章：大量短段落。
  final c3 = StringBuffer(
    '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第三章</title></head>'
    '<body><h2>第三章 短文</h2>',
  );
  for (var i = 0; i < 100; i++) {
    c3.write('<p>第三章第$i段。</p>');
  }
  c3.write('</body></html>');

  final archive = Archive()
    ..add(ArchiveFile.bytes('mimetype', utf8.encode('application/epub+zip')))
    ..add(ArchiveFile.string('META-INF/container.xml', container))
    ..add(ArchiveFile.string('OEBPS/content.opf', opf))
    ..add(ArchiveFile.string('OEBPS/toc.ncx', ncx))
    ..add(ArchiveFile.string('OEBPS/chapter1.xhtml', c1.toString()))
    ..add(ArchiveFile.string('OEBPS/chapter2.xhtml', c2.toString()))
    ..add(ArchiveFile.string('OEBPS/chapter3.xhtml', c3.toString()))
    ..add(ArchiveFile.bytes('OEBPS/images/pic.png', picBytes));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
