/// 分页器测试（FR-202 验收线）：确定性（同输入同输出）/ 连续性 / 覆盖性 /
/// 单调性 / 代理对安全 / 退化视口终止性 / pageIndexOf。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';

const _fontSize = 16.0;
const _lineHeight = 1.5;
const _viewportWidth = 400.0;
const _viewportHeight = 600.0;

TxtPaginationRequest _request(String text, {String? fontFamily}) =>
    TxtPaginationRequest(
      text: text,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      fontFamily: fontFamily,
      viewportWidth: _viewportWidth,
      viewportHeight: _viewportHeight,
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
    test('txtDisplayText：每个段落首行插入 2em 缩进', () {
      const text = '第一段。\n第二段。\n第三段。';
      final display = txtDisplayText(text, 0, text.length);
      expect(
        display,
        '$txtParagraphIndent第一段。\n$txtParagraphIndent第二段。\n$txtParagraphIndent第三段。',
      );
    });

    test('txtDisplayText：空行与 \\r 起始行不缩进（CRLF 空行不加占位）', () {
      const text = '甲段。\n\n乙段。\r\n丙段。';
      final display = txtDisplayText(text, 0, text.length);
      // 空行本身不加缩进（缩进后紧跟换行/回车 = 给空行加了占位）。
      expect(
        display.contains('$txtParagraphIndent\n'),
        isFalse,
        reason: '空行不应插入缩进（否则平白多一行）',
      );
      expect(
        display.contains('$txtParagraphIndent\r'),
        isFalse,
        reason: '\\r 起始行不应插入缩进',
      );
      // 空行之后的正常段落仍缩进。
      expect(display.contains('\n\n$txtParagraphIndent乙段。'), isTrue);
      expect(
        display.contains('\r\n$txtParagraphIndent丙段。'),
        isTrue,
        reason: 'CRLF 行结束后的正常段落仍缩进',
      );
    });

    test('txtDisplayText：续页起点在段中不缩进（页界不产生假段落头）', () {
      const text = '甲段落内容。\n乙段落内容。';
      // 从乙段第二个字符起（段中续行）→ 区间首不缩进。
      final start = text.indexOf('乙') + 1;
      final display = txtDisplayText(text, start, text.length);
      expect(display.startsWith(txtParagraphIndent), isFalse);
      expect(display, '段落内容。');
    });

    test('txtDisplayText：不删改原字符（只插入），区间外不受影响', () {
      const text = '甲。\n乙。';
      final display = txtDisplayText(text, text.indexOf('乙'), text.length);
      expect(display, '$txtParagraphIndent乙。');
      // 全文变换是逐段的真超集：去掉缩进后还原原文。
      final full = txtDisplayText(text, 0, text.length);
      expect(full.replaceAll(txtParagraphIndent, ''), text);
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
          paragraphIndent: txtParagraphIndent,
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
              paragraphIndent: indent ? txtParagraphIndent : '',
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
}
