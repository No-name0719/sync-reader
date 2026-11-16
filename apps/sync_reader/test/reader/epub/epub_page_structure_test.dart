/// epub page 模式**页结构**单元测试（纯 Dart，无 widget）。
///
/// 契约（本次修复的核心，详见 epub_page_structure.dart）：
/// 1. 文本页的终点 = 一屏之内最靠下的行边界候选（页尾留白不足一行）；
/// 2. **插图独占一页**：一屏之内出现图片 → 该页终点 = 图片块顶（插图另起
///    一页）；本页从图片块顶起 → 终点 = 图片块底（页界绝不入图片内部，
///    插图不会被切成两页各露一半）；
/// 3. 前后翻页**精确往返**：下一页 → 上一页 回到原落点（页起点链）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_page_structure.dart';

/// 行边界候选（间距 [step]）。
List<EpubStop> lines(double from, int count, double step) => [
      for (var i = 0; i < count; i++) EpubStop.text(from + i * step),
    ];

/// 正文 0,30,60,90 → 插图 [120,260] → 正文 260,290,320,350。
List<EpubStop> textWithImage() => [
      ...lines(0, 4, 30),
      EpubStop.image(120, 260),
      EpubStop.text(260),
      ...lines(260, 4, 30),
    ];

void main() {
  group('页结构：文本页', () {
    test('后继 = 一屏之内最靠下的行边界', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 20, 30)); // 行边界 0,30,60,…,570

      expect(pages.nextPageStart(0), 90); // 0+100 → 最靠下的候选 90
      expect(pages.nextPageStart(90), 180);
      expect(pages.nextPageStart(180), 270);
    });

    test('后继不跨过一屏（内容超出一屏则没有后继）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 2, 200)); // 0,200（相隔两屏）

      expect(pages.nextPageStart(0), isNull, reason: '一屏内无行边界 → 无下一页');
    });

    test('前驱 = 最靠前的合法候选（上一页排得最满）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 20, 30));

      expect(pages.prevPageStart(90), 0); // [0,90) 排满一屏
      expect(pages.prevPageStart(180), 90);
      expect(pages.prevPageStart(270), 180);
    });

    test('文档顶端没有上一页', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 20, 30));
      expect(pages.prevPageStart(0), isNull);
    });
  });

  group('页结构：插图独占一页', () {
    test('插图块顶是页终点：插图另起一页', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      // 从 0 出发：一屏（200）之内出现插图 → 该页终点 = 插图块顶 120。
      expect(pages.nextPageStart(0), 120);
    });

    test('插图块底是插图页的终点（页界不入图片内部）', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      // 插图页 = [120, 260]：下一页起点 = 图片块底。
      expect(pages.nextPageStart(120), 260);
      // 插图页的上一页 = 图片块顶。
      expect(pages.prevPageStart(260), 120);
    });

    test('插图页之后回到正文行', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      expect(pages.nextPageStart(260), 350); // 一屏内最靠下的行边界
    });

    test('插图前后的正文不共用一页', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      // 插图后的正文页起点不得早于插图块底（否则插图会被切成两页）。
      expect(pages.prevPageStart(290), 260);
      expect(pages.prevPageStart(320), 260);
    });

    test('插图不会被切成两页（页起点不落在图片内部）', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      var at = 0.0;
      final visited = <double>[at];
      for (var i = 0; i < 8; i++) {
        final next = pages.nextPageStart(at);
        if (next == null) break;
        at = next;
        visited.add(at);
      }
      for (final pos in visited) {
        final insideImage = pos > 120 + 0.5 && pos < 260 - 0.5;
        expect(insideImage, isFalse, reason: '页起点 $pos 落在插图内部');
      }
      // 插图恰好占一页（120 → 260 相邻，中间不夹别的页起点）。
      expect(visited[visited.indexOf(120) + 1], 260);
    });
  });

  group('页结构：页起点链（前后精确往返）', () {
    test('下一页 → 上一页 回到原落点', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(textWithImage());

      final path = <double>[0];
      var at = 0.0;
      for (var i = 0; i < 4; i++) {
        final next = pages.nextPageStart(at);
        if (next == null) break;
        at = next;
        path.add(at);
      }
      expect(path.length, greaterThan(2));

      // 逐页退回：每一步都回到前一个落点。
      for (var i = path.length - 1; i > 0; i--) {
        final prev = pages.prevPageStart(path[i]);
        expect(prev, isNotNull);
        expect(prev, closeTo(path[i - 1], 0.5));
      }
    });

    test('就近页起点：落点本身就是页起点时不再挪动（一次按键只翻一页）', () {
      final pages = EpubPageStructure(viewport: 200);
      pages.setStops(lines(0, 20, 30));

      final next = pages.nextPageStart(0)!;
      expect(pages.nearestPageStart(next), closeTo(next, 0.5));
    });
  });

  group('页结构：候选表', () {
    test('整表替换：重复设置同一批候选不产生重复项', () {
      final pages = EpubPageStructure(viewport: 100);
      final measured = lines(0, 5, 30);
      pages.setStops(measured);
      pages.setStops(measured);
      pages.setStops(measured);

      expect(pages.stopCount, 5);
      expect(pages.nextPageStart(0), 90);
    });

    test('整表替换：新测量替换旧测量（块位置微移不留残影）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 5, 30)); // 0,30,60,90,120
      pages.setStops(lines(150, 5, 30)); // 150,180,210,240,270

      expect(pages.stopCount, 5);
      expect(pages.nextPageStart(150), 240);
      // 旧候选已作废（整表替换，不累积）。
      expect(pages.nextPageStart(0), isNull);
    });

    test('clear 后候选与页起点链一并作废', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(lines(0, 5, 30));
      pages.nextPageStart(0);
      expect(pages.chain, isNotEmpty);

      pages.clear();
      expect(pages.stopCount, 0);
      expect(pages.chain, isEmpty);
    });
  });
}
