/// EpubBlockParser 单元测试：块序列与 kind、plainText 与实体解码、
/// 列表拉平与标记、图片 src 解析回调、表格/浮动降级、损坏 XHTML 兜底，
/// 以及 EpubPositionMath 的 href 归一化与字符偏移→块下标换算。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_block_parser.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_locator.dart';

void main() {
  const parser = EpubBlockParser();

  group('块序列与 kind', () {
    test('h1/p/blockquote/ul/img(p 内)/hr 顺序解析', () {
      const source =
          '<html><head><title>t</title>'
          '<style>p{color:red}</style></head><body>'
          '<h1>第一章 起点</h1>'
          '<p>开篇段落。</p>'
          '<blockquote><p>引用名言一段。</p></blockquote>'
          '<ul><li>列表条目甲</li><li>列表条目乙</li></ul>'
          '<p><img src="images/pic.png" alt="插图"/></p>'
          '<hr/>'
          '<p>第一章收尾段落。</p>'
          '</body></html>';
      final blocks = parser.parse(source);

      expect(blocks, hasLength(8));
      expect(blocks[0].kind, EpubBlockKind.heading);
      expect(blocks[0].headingLevel, 1);
      expect(blocks[0].plainText, '第一章 起点');
      // heading 保留 hN 标签（HtmlWidget 自带标题缩放），段落为去标签内层。
      expect(blocks[0].html, startsWith('<h1'));
      expect(blocks[1].kind, EpubBlockKind.paragraph);
      expect(blocks[1].plainText, '开篇段落。');
      expect(blocks[1].html, '开篇段落。');
      expect(blocks[2].kind, EpubBlockKind.quote);
      expect(blocks[2].plainText, '引用名言一段。');
      expect(blocks[3].kind, EpubBlockKind.listItem);
      expect(blocks[3].listMarker, '•');
      expect(blocks[4].kind, EpubBlockKind.listItem);
      expect(blocks[4].listMarker, '•');
      expect(blocks[5].kind, EpubBlockKind.paragraph); // p 内图片：含 img 的段落
      expect(blocks[5].html, contains('<img'));
      expect(blocks[6].kind, EpubBlockKind.hr);
      expect(blocks[7].kind, EpubBlockKind.paragraph);
      expect(blocks[7].plainText, '第一章收尾段落。');
    });

    test('独立 img 块与 src 解析回调（解析期替换为 data URI）', () {
      const source =
          '<html><body><img src="images/pic.png" alt="插图"/></body></html>';
      final blocks = parser.parse(
        source,
        resolveImage: (src) =>
            src == 'images/pic.png' ? 'data:image/png;base64,QUJD' : null,
      );
      expect(blocks, hasLength(1));
      expect(blocks[0].kind, EpubBlockKind.image);
      expect(blocks[0].html, contains('data:image/png;base64,QUJD'));
      expect(blocks[0].plainText, '插图'); // alt 为图片块坐标基准
      expect(blocks[0].hasContent, isTrue);
    });

    test('ol 有序标记与嵌套列表拉平为条目序列', () {
      const source =
          '<html><body><ol>'
          '<li>第一项</li>'
          '<li>第二项<ul><li>嵌套子项</li></ul></li>'
          '</ol></body></html>';
      final blocks = parser.parse(source);
      expect(blocks.map((b) => b.kind), everyElement(EpubBlockKind.listItem));
      expect(blocks, hasLength(3));
      expect(blocks[0].listMarker, '1.');
      expect(blocks[1].listMarker, '2.');
      expect(blocks[2].listMarker, '◦'); // 嵌套层
      expect(blocks[1].plainText, '第二项'); // 嵌套项文本不重复计入本块
      expect(blocks[2].plainText, '嵌套子项');
    });

    test('div 容器递归；无块级子元素的 div/span 收拢为段落', () {
      const source =
          '<html><body>'
          '<div><section><h2>小节</h2><p>节内段落。</p></section></div>'
          '<div>行内<strong>内容</strong>段落</div>'
          '<span>游离内联</span>'
          '</body></html>';
      final blocks = parser.parse(source);
      expect(blocks, hasLength(4));
      expect(blocks[0].kind, EpubBlockKind.heading);
      expect(blocks[1].kind, EpubBlockKind.paragraph);
      expect(blocks[2].kind, EpubBlockKind.paragraph);
      expect(blocks[2].plainText, '行内内容段落');
      expect(blocks[3].kind, EpubBlockKind.paragraph);
      expect(blocks[3].plainText, '游离内联');
    });

    test('h2–h6 层级与未识别元素 other 原样保留', () {
      const source =
          '<html><body>'
          '<h3>三级标题</h3><svg><circle/></svg>'
          '</body></html>';
      final blocks = parser.parse(source);
      expect(blocks[0].headingLevel, 3);
      expect(blocks[1].kind, EpubBlockKind.other);
      expect(blocks[1].html, contains('<svg'));
    });
  });

  group('plainText 与实体', () {
    test('HTML 实体解码与空白折叠', () {
      const source =
          '<html><body>'
          '<p>甲&amp;乙&lt;丙&#x4e01;</p>'
          '<p>多行\n\t文本   折叠&#160;为一段</p>'
          '</body></html>';
      final blocks = parser.parse(source);
      expect(blocks[0].plainText, '甲&乙<丙丁');
      expect(blocks[1].plainText, '多行 文本 折叠\u{A0}为一段');
      // 偏移坐标 = plainText 长度（含实体解码后的字符）。
      expect(blocks[0].plainText.length, 6);
    });

    test('空段落/纯样式内容不产生块', () {
      const source =
          '<html><body><p>   </p><div></div>'
          '<script>var x = 1;</script></body></html>';
      expect(parser.parse(source), isEmpty);
    });
  });

  group('复杂排版降级', () {
    test('表格折叠为顺序文本并标 degraded，保留单元格文字', () {
      const source =
          '<html><body><table>'
          '<tr><th>名称</th><th>数量</th></tr>'
          '<tr><td>苹果</td><td>3</td></tr>'
          '</table></body></html>';
      final blocks = parser.parse(source);
      expect(blocks, hasLength(1));
      final block = blocks.single;
      expect(block.kind, EpubBlockKind.paragraph);
      expect(block.degraded, isTrue);
      expect(block.plainText, contains('名称'));
      expect(block.plainText, contains('数量'));
      expect(block.plainText, contains('苹果'));
      expect(block.plainText, contains('3'));
    });

    test('float 浮动样式标记 degraded', () {
      const source =
          '<html><body><p style="float:left; width:40%">浮动段落</p>'
          '</body></html>';
      final blocks = parser.parse(source);
      expect(blocks.single.degraded, isTrue);
      expect(blocks.single.plainText, '浮动段落');
    });

    test('损坏 XHTML 兜底：去标签单块 degraded，不抛异常', () {
      const source = '<html><body><p>未闭合段落';
      final blocks = parser.parse(source);
      expect(blocks, hasLength(1));
      final block = blocks.single;
      expect(block.kind, EpubBlockKind.paragraph);
      expect(block.degraded, isTrue);
      expect(block.plainText, contains('未闭合段落'));
    });
  });

  group('EpubPositionMath', () {
    test('normalizeHref：fragment/URL 编码/相对段/反斜杠归一', () {
      expect(
        EpubPositionMath.normalizeHref('chapter2.xhtml#sec-1'),
        'chapter2.xhtml',
      );
      expect(
        EpubPositionMath.normalizeHref('my%20chapter.xhtml'),
        'my chapter.xhtml',
      );
      expect(
        EpubPositionMath.normalizeHref('text/../images/./pic.png'),
        'images/pic.png',
      );
      expect(
        EpubPositionMath.normalizeHref(r'text\ch1.xhtml'),
        'text/ch1.xhtml',
      );
      expect(EpubPositionMath.normalizeHref('ch1.xhtml?from=toc'), 'ch1.xhtml');
      expect(EpubPositionMath.normalizeHref('//a//b//'), 'a/b');
    });

    test('flatIndexAtCharOffset：前缀和二分定位', () {
      // 块长度 [3, 0, 5, 2] → 前缀和 [0, 3, 3, 8]。
      const prefix = [0, 3, 3, 8];
      expect(EpubPositionMath.flatIndexAtCharOffset(prefix, 0), 0);
      expect(EpubPositionMath.flatIndexAtCharOffset(prefix, 2), 0);
      expect(EpubPositionMath.flatIndexAtCharOffset(prefix, 3), 2); // 空块跳过
      expect(EpubPositionMath.flatIndexAtCharOffset(prefix, 7), 2);
      expect(EpubPositionMath.flatIndexAtCharOffset(prefix, 100), 3);
      expect(EpubPositionMath.flatIndexAtCharOffset(const [], 5), -1);
    });
  });

  group('EpubLocatorCodec', () {
    test('编码字段名与 sync_core EpubLocator.toJson 一致', () {
      final json = EpubLocatorCodec.encode(
        spineIndex: 2,
        href: 'OEBPS/ch05.xhtml',
        blockIndex: 7,
        charOffset: 120,
      );
      expect(
        json,
        '{"type":"epub","spineIndex":2,"href":"OEBPS/ch05.xhtml",'
        '"blockIndex":7,"charOffset":120}',
      );
    });

    test('tryDecode：合法/非法输入', () {
      final ok = EpubLocatorCodec.tryDecode(
        '{"type":"epub","spineIndex":1,"href":"c.xhtml",'
        '"blockIndex":0,"charOffset":5}',
      );
      expect(ok, isNotNull);
      expect(ok!.spineIndex, 1);
      expect(ok.href, 'c.xhtml');
      expect(ok.blockIndex, 0);
      expect(ok.charOffset, 5);

      // type 不符 / 字段缺失 / 损坏 JSON / 空 href。
      expect(
        EpubLocatorCodec.tryDecode('{"type":"txt","chapterIndex":1}'),
        isNull,
      );
      expect(
        EpubLocatorCodec.tryDecode(
          '{"type":"epub","spineIndex":1,"blockIndex":0,"charOffset":0}',
        ),
        isNull,
      );
      expect(EpubLocatorCodec.tryDecode('not-json{{'), isNull);
      expect(EpubLocatorCodec.tryDecode(null), isNull);
    });
  });

  group('EpubSpineAnchor', () {
    test('toString 形态冻结（指纹依赖）', () {
      const anchor = EpubSpineAnchor(spineIndex: 3, href: 'text/ch4.xhtml');
      expect(anchor.toString(), 'epub:spine:3:text/ch4.xhtml');
    });

    test('tryParse 往返（href 含冒号/fragment）', () {
      const anchor = EpubSpineAnchor(spineIndex: 0, href: 'c1.xhtml#fig-1:2');
      final parsed = EpubSpineAnchor.tryParse(anchor.toString());
      expect(parsed, anchor);
      expect(EpubSpineAnchor.tryParse('md:heading:1:2'), isNull);
    });
  });
}
