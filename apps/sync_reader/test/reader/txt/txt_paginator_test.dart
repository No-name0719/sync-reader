/// 分页器测试（FR-202 验收线）：确定性（同输入同输出）/ 连续性 / 覆盖性 /
/// 单调性 / 代理对安全 / 退化视口终止性 / pageIndexOf。
library;

import 'package:flutter/foundation.dart';
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
}
