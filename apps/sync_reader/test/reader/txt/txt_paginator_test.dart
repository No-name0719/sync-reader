/// 分页器测试（FR-202 + v1.2 B1 整行分页验收线）：确定性（同输入同输出）/
/// 连续性 / 覆盖性 / 单调性 / 代理对安全 / 退化视口终止性 / pageIndexOf /
/// **整行性（B1：页界落在行与行之间，无半行）**。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/reader_indent.dart';

/// 缩进占位符在扁平文本里的样子（U+FFFC，行内不可见盒）。
///
/// 缩进不再用全角空格（两端对齐会吞掉行首空白），改用行内占位符，
/// 因此显示层纯文本里每个缩进是 **1 个** U+FFFC（不是 2 个 U+3000）。
const _indentMark = '￼';

const _fontSize = 16.0;
const _lineHeight = 1.5;
const _viewportWidth = 400.0;
const _viewportHeight = 600.0;

/// 与 [_request] 同参数的字体样式（fontFamily 同为 null，走同一默认字体，
/// 保证测试内测量与分页器测量行盒一致）。
TextStyle get _testStyle => const TextStyle(fontSize: _fontSize, height: _lineHeight);

TxtPaginationRequest _request(
  String text, {
  String? fontFamily,
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) => TxtPaginationRequest(
  text: text,
  fontSize: _fontSize,
  lineHeight: _lineHeight,
  fontFamily: fontFamily,
  indentEm: indentEm,
  paragraphGapLines: paragraphGapLines,
  viewportWidth: _viewportWidth,
  viewportHeight: _viewportHeight,
);

/// 排版一段显示文本并返回行数（测试内测量行盒，与分页器同引擎同字体；
/// 宽度必须与分页视口一致，否则行断点不可比）。
int _lineCount(TextSpan span, double width, {int indentCount = 0}) {
  final painter = TextPainter(textDirection: TextDirection.ltr, text: span);
  painter.setPlaceholderDimensions(
    List<PlaceholderDimensions>.filled(
      indentCount,
      readerIndentPlaceholder(_fontSize),
    ),
  );
  painter.layout(maxWidth: width);
  final n = painter.computeLineMetrics().length;
  painter.dispose();
  return n;
}

/// span 树里缩进占位符的数量（测量时用来喂占位符尺寸）。
int _indentCount(TextSpan span) {
  var n = 0;
  span.visitChildren((InlineSpan child) {
    if (child is WidgetSpan) n++;
    return true;
  });
  return n;
}

/// 章内区间的显示层 span 树（与分页器/渲染侧同一变换）。
TextSpan _displaySpan(
  String text,
  int start,
  int end, {
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) => txtDisplaySpan(
  text,
  start,
  end,
  style: _testStyle,
  fontSize: _fontSize,
  indentEm: indentEm,
  paragraphGapLines: paragraphGapLines,
);

/// 章内区间的**单页**显示层 span 树。
TextSpan _pageSpan(
  String text,
  int start,
  int end, {
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) => txtPageDisplaySpan(
  text,
  start,
  end,
  style: _testStyle,
  fontSize: _fontSize,
  indentEm: indentEm,
  paragraphGapLines: paragraphGapLines,
);

String _sampleText({int lines = 200}) => List<String>.generate(
  lines,
  (i) => '第$i行的一些中文内容用来填充排版测试，长度略有差异 $i。',
).join('\n');

/// 断言分页结果满足全部结构不变量。
void _expectInvariants(List<TxtPageRange> pages, int length) {
  expect(pages, isNotEmpty);
  expect(pages.first.start, 0, reason: '首页从 0 起');
  expect(pages.last.end, length, reason: '末页到全文末尾');
  for (var i = 0; i < pages.length; i++) {
    expect(pages[i].end, greaterThan(pages[i].start), reason: '第$i页非空（单调性）');
    if (i > 0) {
      expect(pages[i].start, pages[i - 1].end, reason: '第$i页与前页相接（连续性）');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paginateSync 不变量', () {
    test('长章多页：连续 / 覆盖 / 单调递增', () {
      final text = _sampleText();
      final pages = TxtPaginator.paginateSync(_request(text));
      expect(pages.length, greaterThan(3), reason: '长文本应切出多页');
      _expectInvariants(pages, text.length);
    });

    test('确定性：同输入同输出', () {
      final text = _sampleText(lines: 120);
      final a = TxtPaginator.paginateSync(_request(text));
      final b = TxtPaginator.paginateSync(_request(text));
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i], reason: '第$i页');
      }
      expect(listEquals(a, b), isTrue);
    });

    test('样式不变性：字号变化后仍满足不变量', () {
      final text = _sampleText(lines: 80);
      for (final fontSize in [12.0, 16.0, 24.0, 32.0]) {
        final pages = TxtPaginator.paginateSync(
          TxtPaginationRequest(
            text: text,
            fontSize: fontSize,
            lineHeight: _lineHeight,
            viewportWidth: _viewportWidth,
            viewportHeight: _viewportHeight,
          ),
        );
        _expectInvariants(pages, text.length);
      }
    });

    test('空文本 → 单空页', () {
      final pages = TxtPaginator.paginateSync(_request(''));
      expect(pages, const [TxtPageRange(start: 0, end: 0)]);
    });

    test('退化视口（0 尺寸）→ 单页覆盖全章，保证可用', () {
      const text = '退化视口的内容';
      final pages = TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: 0,
          viewportHeight: 0,
        ),
      );
      expect(pages, [TxtPageRange(start: 0, end: text.length)]);
    });

    test('极小视口：1 字符页推进，必然终止', () {
      const text = '一二三四五六七八九十';
      final pages = TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: 5,
          viewportHeight: 5,
        ),
      );
      expect(pages.length, text.length, reason: '每页 1 字符');
      _expectInvariants(pages, text.length);
    });

    test('代理对安全：页界不落在代理对中间且区间不变量成立', () {
      final text = '😀' * 800;
      final pages = TxtPaginator.paginateSync(_request(text));
      _expectInvariants(pages, text.length);
      for (var i = 0; i < pages.length - 1; i++) {
        final lastUnit = text.codeUnitAt(pages[i].end - 1);
        final isHighSurrogate = lastUnit >= 0xD800 && lastUnit <= 0xDBFF;
        expect(isHighSurrogate, isFalse, reason: '第$i页末尾不应是高代理');
      }
    });

    test('章为页边界：不同章独立分页，各自覆盖', () {
      final chapterA = '甲' * 2000;
      final chapterB = '乙' * 800;
      final pagesA = TxtPaginator.paginateSync(_request(chapterA));
      final pagesB = TxtPaginator.paginateSync(_request(chapterB));
      _expectInvariants(pagesA, chapterA.length);
      _expectInvariants(pagesB, chapterB.length);
    });
  });

  group('paginate（isolate）', () {
    test('isolate 结果与同步一致（同引擎同字体）', () async {
      final text = _sampleText(lines: 100);
      final sync = TxtPaginator.paginateSync(_request(text));
      final async = await TxtPaginator.paginate(_request(text));
      expect(listEquals(async, sync), isTrue);
    });
  });

  group('pageIndexOf', () {
    test('二分定位包含偏移的页；越界落末页', () {
      const pages = [
        TxtPageRange(start: 0, end: 10),
        TxtPageRange(start: 10, end: 20),
        TxtPageRange(start: 20, end: 25),
      ];
      expect(TxtPaginator.pageIndexOf(pages, 0), 0);
      expect(TxtPaginator.pageIndexOf(pages, 9), 0);
      expect(TxtPaginator.pageIndexOf(pages, 10), 1);
      expect(TxtPaginator.pageIndexOf(pages, 24), 2);
      expect(TxtPaginator.pageIndexOf(pages, 100), 2, reason: '越界钳到末页');
      expect(TxtPaginator.pageIndexOf(const [], 5), 0);
    });
  });

  group('v1.1 A10 中文排版（首行缩进 + 两端对齐）', () {
    test('显示层变换：每个段落首行插入 2em 缩进', () {
      const text = '第一段。\n第二段。\n第三段。';
      final display = _displaySpan(text, 0, text.length).toPlainText();
      expect(
        display,
        '$_indentMark第一段。\n$_indentMark第二段。\n$_indentMark第三段。',
      );
    });

    test('显示层变换：空行与 \\r 起始行不缩进（CRLF 空行不加占位）', () {
      const text = '甲段。\n\n乙段。\r\n丙段。';
      final display = _displaySpan(text, 0, text.length).toPlainText();
      // 空行本身不加缩进（缩进后紧跟换行/回车 = 给空行加了占位）。
      expect(
        display.contains('$_indentMark\n'),
        isFalse,
        reason: '空行不应插入缩进（否则平白多一行）',
      );
      expect(
        display.contains('$_indentMark\r'),
        isFalse,
        reason: '\\r 起始行不应插入缩进',
      );
      // 空行之后的正常段落仍缩进。
      expect(display.contains('\n\n$_indentMark乙段。'), isTrue);
      expect(
        display.contains('\r\n$_indentMark丙段。'),
        isTrue,
        reason: 'CRLF 行结束后的正常段落仍缩进',
      );
    });

    test('显示层变换：续页起点在段中不缩进（页界不产生假段落头）', () {
      const text = '甲段落内容。\n乙段落内容。';
      // 从乙段第二个字符起（段中续行）→ 区间首不缩进。
      final start = text.indexOf('乙') + 1;
      final display = _displaySpan(text, start, text.length).toPlainText();
      expect(display.startsWith(_indentMark), isFalse);
      expect(display, '段落内容。');
    });

    test('显示层变换：不删改原字符（只插入），区间外不受影响', () {
      const text = '甲。\n乙。';
      final display = _displaySpan(text, text.indexOf('乙'), text.length).toPlainText();
      expect(display, '$_indentMark乙。');
      // 全文变换是逐段的真超集：去掉缩进后还原原文。
      final full = _displaySpan(text, 0, text.length).toPlainText();
      expect(full.replaceAll(_indentMark, ''), text);
    });

    test('缩进 + justify 分页：结构不变量仍成立', () {
      final text = _sampleText(lines: 80);
      final pages = TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
          indentEm: kReaderParagraphIndentEm,
          textAlign: TextAlign.justify,
        ),
      );
      expect(pages.length, greaterThan(3));
      _expectInvariants(pages, text.length);
    });

    test('缩进参与排版：同视口下首页容纳字符数不多于无缩进（不溢出）', () {
      final text = _sampleText(lines: 60);
      List<TxtPageRange> paginate({required bool indent}) =>
          TxtPaginator.paginateSync(
            TxtPaginationRequest(
              text: text,
              fontSize: _fontSize,
              lineHeight: _lineHeight,
              viewportWidth: _viewportWidth,
              viewportHeight: _viewportHeight,
              indentEm: indent ? kReaderParagraphIndentEm : 0,
            ),
          );
      final withIndent = paginate(indent: true);
      final withoutIndent = paginate(indent: false);
      expect(
        withIndent.first.end,
        lessThanOrEqualTo(withoutIndent.first.end),
        reason: '缩进字符参与测量：每段首行变长，首页容量不增（不产生视口溢出）',
      );
      expect(withoutIndent.first.end, lessThan(text.length));
    });

    test('justify 与 left 测量行断点一致（justify 不改变换页位置）', () {
      final text = _sampleText(lines: 60);
      List<TxtPageRange> paginate(TextAlign align) => TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
          textAlign: align,
        ),
      );
      final justified = paginate(TextAlign.justify);
      final left = paginate(TextAlign.left);
      expect(justified.length, left.length, reason: 'justify 不改变行断点');
      for (var i = 0; i < justified.length; i++) {
        expect(justified[i], left[i], reason: '第$i页断点应一致');
      }
    });
  });

  group('v1.2 B1 整行分页（页界落在行与行之间，无半行）', () {
    /// 断言一页独立排版的高度不超过视口（页尾不足一行时留白而不是溢出）。
    /// 用 [_pageSpan] 与渲染侧同口径（页尾分页符不渲染空行盒）。
    void expectPageFits(
      String text,
      TxtPageRange page,
      double width, {
      double height = _viewportHeight,
    }) {
      final span = _pageSpan(text, page.start, page.end);
      final painter = TextPainter(textDirection: TextDirection.ltr, text: span);
      painter.setPlaceholderDimensions(
        List<PlaceholderDimensions>.filled(
          _indentCount(span),
          readerIndentPlaceholder(_fontSize),
        ),
      );
      painter.layout(maxWidth: width);
      expect(
        painter.height,
        lessThanOrEqualTo(height + 0.01),
        reason: '第 ${page.start}..${page.end} 页渲染高度应在视口内',
      );
      painter.dispose();
    }

    /// 断言相邻两页的切点落在行边界：两页各自排版行数之和 == 两页并集区间
    /// 排版行数。若切点落在某行中间，并集会把两半拼回一行，行数少 1。
    void expectCutOnLineBoundary(
      String text,
      TxtPageRange a,
      TxtPageRange b, {
      int gapLines = 0,
      double width = _viewportWidth,
    }) {
      final spanA = _pageSpan(text, a.start, a.end, paragraphGapLines: gapLines);
      final spanB = _pageSpan(text, b.start, b.end, paragraphGapLines: gapLines);
      final spanUnion = _pageSpan(
        text,
        a.start,
        b.end,
        paragraphGapLines: gapLines,
      );
      final countA = _lineCount(spanA, width, indentCount: _indentCount(spanA));
      final countB = _lineCount(spanB, width, indentCount: _indentCount(spanB));
      final countUnion = _lineCount(
        spanUnion,
        width,
        indentCount: _indentCount(spanUnion),
      );
      // 并集区间里，b 的首段若为段落首且上一行有内容则插入段距空行
      // （单页排版时页首段落收起段距），需要按条件补回。
      final boundaryIsParagraphStart =
          b.start > 0 && text.codeUnitAt(b.start - 1) == 0x0A;
      final prevLineHasContent = boundaryIsParagraphStart
          ? _prevLineHasContentForTest(text, b.start - 1)
          : false;
      final gapAtBoundary =
          gapLines > 0 && boundaryIsParagraphStart && prevLineHasContent
          ? gapLines
          : 0;
      expect(
        countUnion,
        countA + countB + gapAtBoundary,
        reason:
            '页界 $a | $b 应落在行边界（并集行数 = 两页行数之和，'
            '出现半行时会少 1）',
      );
    }

    test('无半行：相邻页拼接行数守恒（正文多段多页）', () {
      final text = _sampleText(lines: 120);
      final pages = TxtPaginator.paginateSync(_request(text));
      expect(pages.length, greaterThan(3));
      for (var i = 0; i < pages.length; i++) {
        expectPageFits(text, pages[i], _viewportWidth);
        if (i + 1 < pages.length) {
          expectCutOnLineBoundary(text, pages[i], pages[i + 1]);
        }
      }
    });

    test('无半行：justify 两端对齐下同样成立', () {
      final text = _sampleText(lines: 80);
      final pages = TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: _viewportWidth,
          viewportHeight: _viewportHeight,
          indentEm: kReaderParagraphIndentEm,
          textAlign: TextAlign.justify,
        ),
      );
      expect(pages.length, greaterThan(3));
      for (var i = 0; i + 1 < pages.length; i++) {
        expectCutOnLineBoundary(text, pages[i], pages[i + 1]);
      }
    });

    test('段距（整行空行）下页界仍是行边界且页高不超视口', () {
      final text = _sampleText(lines: 60);
      for (final gap in [1, 2]) {
        final pages = TxtPaginator.paginateSync(
          _request(text, paragraphGapLines: gap),
        );
        expect(pages.length, greaterThan(3), reason: '段距 $gap');
        for (var i = 0; i < pages.length; i++) {
          expectPageFits(text, pages[i], _viewportWidth);
          if (i + 1 < pages.length) {
            expectCutOnLineBoundary(
              text,
              pages[i],
              pages[i + 1],
              gapLines: gap,
            );
          }
        }
      }
    });

    test('段距只加在相邻内容段之间：原文空行分隔的段落不叠加', () {
      const text = '甲段。\n\n乙段。\n丙段。';
      final display = _displaySpan(
        text,
        0,
        text.length,
        paragraphGapLines: 1,
      ).toPlainText();
      // 乙段前已有原文空行 → 不再叠加段距；丙段前是相邻内容行 → 叠加 1 行。
      expect(display.contains('甲段。\n\n$_indentMark乙段。'), isTrue);
      expect(
        display.contains('$_indentMark乙段。\n\n$_indentMark丙段。'),
        isTrue,
        reason: '乙段与丙段之间 = 段尾换行 + 1 空行段距（共两个 \\n）',
      );
    });

    test('页首段落不插段距（跨页收起）：单页显示文本不以空行开头', () {
      final text = _sampleText(lines: 40);
      final pages = TxtPaginator.paginateSync(
        _request(text, paragraphGapLines: 2),
      );
      expect(pages.length, greaterThan(2));
      for (final page in pages.skip(1)) {
        final display = _displaySpan(
          text,
          page.start,
          page.end,
          paragraphGapLines: 2,
        ).toPlainText();
        expect(
          display.startsWith('\n'),
          isFalse,
          reason: '页 ${page.start} 起点是段落首时不得以段距空行开头',
        );
      }
    });

    test('窄视口退化：仍满足结构不变量与整行性', () {
      // 48px = 3 字宽：窄于任何真实设备，但宽于 2em 缩进（32px）——
      // 缩进自身不跨行的下限。再窄（如 24px）缩进会跨行，页界退化为
      // 字符推进（分页器文档注明），整行性不再成立，属病态输入。
      final text = _sampleText(lines: 20);
      final pages = TxtPaginator.paginateSync(
        TxtPaginationRequest(
          text: text,
          fontSize: _fontSize,
          lineHeight: _lineHeight,
          viewportWidth: 48,
          viewportHeight: 30,
        ),
      );
      _expectInvariants(pages, text.length);
      for (var i = 0; i < pages.length; i++) {
        expectPageFits(text, pages[i], 48, height: 30);
        if (i + 1 < pages.length) {
          expectCutOnLineBoundary(text, pages[i], pages[i + 1], width: 48);
        }
      }
    });
  });
}

/// 测试内复刻分页器的段距前置条件：`newlineIndex` 处换行符结束的上一行
/// 是否有内容（剥掉 CRLF 的 '\r'）。
bool _prevLineHasContentForTest(String text, int newlineIndex) {
  var i = newlineIndex - 1;
  if (i < 0) return false;
  while (i >= 0 && text.codeUnitAt(i) != 0x0A) {
    i--;
  }
  var end = newlineIndex;
  if (end > i + 1 && text.codeUnitAt(end - 1) == 0x0D) end--;
  return end > i + 1;
}
