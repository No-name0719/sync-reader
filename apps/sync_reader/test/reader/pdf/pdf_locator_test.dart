/// pdf locator 编解码 + restore 决策 + 页码校验单测（FR-205/207、
/// docs/05 §3.3）。决策表逐行覆盖：无进度 / 精确 / 损坏降级 / 越界降级。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_locator.dart';

void main() {
  group('encodePdfLocator / parsePdfLocator（序列化往返）', () {
    test('编码产出 docs/05 §3.3 契约 JSON', () {
      final json = encodePdfLocator(41, 0.35);
      expect(json, contains('"type":"pdf"'));
      expect(json, contains('"pageIndex":41'));
      expect(json, contains('"yRatio":0.35'));
      expect(json, contains('"readingDir":"ltr"'));
    });

    test('往返：encode → parse 还原相等', () {
      final locator = parsePdfLocator(encodePdfLocator(41, 0.35));
      expect(locator, isNotNull);
      expect(locator!.pageIndex, 41);
      expect(locator.yRatio, 0.35);
      expect(locator.readingDir, 'ltr');
    });

    test('损坏 JSON / 非 Map / 空 null → null', () {
      expect(parsePdfLocator('{broken'), isNull);
      expect(parsePdfLocator('[1,2,3]'), isNull);
      expect(parsePdfLocator(''), isNull);
      expect(parsePdfLocator(null), isNull);
    });

    test('type 不符（raw/epub/txt）→ null（触发 percent 降级）', () {
      expect(parsePdfLocator('{"type":"raw","ratio":0.4}'), isNull);
      expect(
        parsePdfLocator('{"type":"txt","chapterIndex":1,"charOffset":2}'),
        isNull,
      );
      expect(parsePdfLocator('{"pageIndex":3}'), isNull); // 缺 type
    });

    test('缺 pageIndex / 非整数 pageIndex → null', () {
      expect(parsePdfLocator('{"type":"pdf"}'), isNull);
      expect(parsePdfLocator('{"type":"pdf","pageIndex":"41"}'), isNull);
      expect(parsePdfLocator('{"type":"pdf","pageIndex":41.5}'), isNull);
    });

    test('跨端容忍：整型 num（41.0）可解析；缺 yRatio 默认 0', () {
      final locator = parsePdfLocator('{"type":"pdf","pageIndex":41.0}');
      expect(locator, isNotNull);
      expect(locator!.pageIndex, 41);
      expect(locator.yRatio, 0.0);
    });

    test('yRatio 越界钳制到 0–1', () {
      expect(
        parsePdfLocator('{"type":"pdf","pageIndex":1,"yRatio":2.5}')!.yRatio,
        1.0,
      );
      expect(
        parsePdfLocator('{"type":"pdf","pageIndex":1,"yRatio":-1}')!.yRatio,
        0.0,
      );
    });
  });

  group('percent 双向换算（percent = 已读页数占比）', () {
    test('percentForPage：(i+1)/n，含首尾页', () {
      expect(percentForPage(0, 100), 0.01);
      expect(percentForPage(41, 100), 0.42);
      expect(percentForPage(99, 100), 1.0);
    });

    test('percentForPage 退化：n<=0 → 0；越界页码钳制', () {
      expect(percentForPage(0, 0), 0);
      expect(percentForPage(5, -1), 0);
      expect(percentForPage(200, 100), 1.0);
      expect(percentForPage(-3, 100), 0.0);
    });

    test('往返精确：i → percent → i（抽样含边界）', () {
      const pageCount = 337;
      for (final i in [0, 1, 41, 168, 335, 336]) {
        expect(
          pageIndexForPercent(percentForPage(i, pageCount), pageCount),
          i,
          reason: 'page $i 往返失败',
        );
      }
    });

    test('percent 0/1 与退化输入', () {
      expect(pageIndexForPercent(0, 100), 0);
      expect(pageIndexForPercent(1.0, 100), 99);
      expect(pageIndexForPercent(0.5, 0), 0);
      expect(pageIndexForPercent(-1, 100), 0);
      expect(pageIndexForPercent(7, 100), 99); // 越界钳制
    });
  });

  group('decideRestore 决策表', () {
    test('无进度 → noProgress，applied 为空锚点', () {
      final d = decideRestore(ProgressAnchor.empty, 100);
      expect(d.mode, ReaderRestoreMode.noProgress);
      expect(d.targetPageIndex, 0);
      expect(d.applied, ProgressAnchor.empty);
    });

    test('pdf locator 在界内 → exact，applied 为规范化锚点', () {
      final saved = ProgressAnchor(
        locatorJson: encodePdfLocator(41, 0.35),
        percent: 0.42,
      );
      final d = decideRestore(saved, 100);
      expect(d.mode, ReaderRestoreMode.exact);
      expect(d.targetPageIndex, 41);
      expect(d.yRatio, 0.35);
      expect(d.applied.hasProgress, isTrue);
      expect(d.applied.locatorJson, encodePdfLocator(41, 0.35));
      expect(d.applied.percent, 0.42);
    });

    test(
      'locator 损坏 + 有进度 → degradedToPercent，applied 保留 percent、locator 空',
      () {
        const saved = ProgressAnchor(locatorJson: '{corrupted', percent: 0.42);
        final d = decideRestore(saved, 100);
        expect(d.mode, ReaderRestoreMode.degradedToPercent);
        expect(d.targetPageIndex, 41); // round(0.42*100 - 1)
        expect(d.applied.locatorJson, '{}');
        expect(d.applied.percent, 0.42);
        expect(d.applied.hasProgress, isTrue);
      },
    );

    test('locator 类型不符（他端 txt）→ degradedToPercent', () {
      final saved = const ProgressAnchor(
        locatorJson: '{"type":"txt","chapterIndex":3,"charOffset":9}',
        percent: 0.1,
      );
      final d = decideRestore(saved, 100);
      expect(d.mode, ReaderRestoreMode.degradedToPercent);
      expect(d.targetPageIndex, 9); // round(0.1*100 - 1)
    });

    test('页码越界（负值 / >= pageCount）→ degradedToPercent', () {
      final negative = decideRestore(
        ProgressAnchor(locatorJson: encodePdfLocator(-1, 0), percent: 0.3),
        100,
      );
      expect(negative.mode, ReaderRestoreMode.degradedToPercent);
      expect(negative.targetPageIndex, 29);

      final overflow = decideRestore(
        ProgressAnchor(
          locatorJson: encodePdfLocator(100, 0), // 0 起，100 越界（n=100）
          percent: 0.7,
        ),
        100,
      );
      expect(overflow.mode, ReaderRestoreMode.degradedToPercent);
      expect(overflow.targetPageIndex, 69);
    });

    test('最后一页恰好是边界值（n-1）→ exact', () {
      final d = decideRestore(
        ProgressAnchor(locatorJson: encodePdfLocator(99, 1.0), percent: 1.0),
        100,
      );
      expect(d.mode, ReaderRestoreMode.exact);
      expect(d.targetPageIndex, 99);
    });

    test('退化文档（pageCount<=0）→ noProgress', () {
      final d = decideRestore(
        ProgressAnchor(locatorJson: encodePdfLocator(3, 0), percent: 0.5),
        0,
      );
      expect(d.mode, ReaderRestoreMode.noProgress);
      expect(d.targetPageIndex, 0);
    });
  });

  group('parsePageInput（页码跳转输入校验，1 起 → 0 起）', () {
    test('合法输入（含首尾边界与空白）', () {
      expect(parsePageInput('1', 120), 0);
      expect(parsePageInput('120', 120), 119);
      expect(parsePageInput(' 42 ', 120), 41);
    });

    test('非法输入 → null', () {
      expect(parsePageInput('', 120), isNull);
      expect(parsePageInput('abc', 120), isNull);
      expect(parsePageInput('12.5', 120), isNull);
      expect(parsePageInput('0', 120), isNull);
      expect(parsePageInput('-3', 120), isNull);
      expect(parsePageInput('121', 120), isNull);
    });

    test('退化文档（pageCount<=0）恒 null', () {
      expect(parsePageInput('1', 0), isNull);
      expect(parsePageInput('1', -1), isNull);
    });
  });
}
