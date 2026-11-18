/// 分页翻页的**公共规格**（v1.4.4 / docs/10 §9.21）。
///
/// 四种格式（txt / epub / md / pdf）的分页翻页必须用同一套时长、缓动、
/// 阈值与阻尼——「换一本书像换了个阅读器」是本轮要消灭的体验分裂。
///
/// 本文件钉死这些数字与判定规则：任何格式私自改参数、或公共规格被改动，
/// 这里的用例都会红。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/reader_page_turn.dart';

void main() {
  group('公共规格常量（全格式唯一来源）', () {
    test('时长 280ms / 缓动 easeOutCubic', () {
      expect(ReaderPageTurnSpec.duration, const Duration(milliseconds: 280));
      expect(ReaderPageTurnSpec.curve, Curves.easeOutCubic);
    });

    test('过阈值距离：视口宽的 25%，夹在 56–120px', () {
      expect(ReaderPageTurnSpec.threshold(390), closeTo(97.5, 0.01));
      expect(ReaderPageTurnSpec.threshold(200), 56, reason: '窄视口用下限（比例太小难翻）');
      expect(ReaderPageTurnSpec.threshold(1440), 120, reason: '宽视口用上限（比例太大难翻）');
    });

    test('边界回弹幅度 24px / 越界阻尼 0.4', () {
      expect(ReaderPageTurnSpec.overscroll, 24);
      expect(ReaderPageTurnSpec.resistance, 0.4);
    });
  });

  group('越界阻尼', () {
    test('视口内的位移 1:1（跟手，不缩放）', () {
      expect(ReaderPageTurnSpec.resistedTravel(-100, 400), -100);
      expect(ReaderPageTurnSpec.resistedTravel(100, 400), 100);
    });

    test('越界位移被阻尼并封顶（拖过头也只多走一点点）', () {
      final travel = ReaderPageTurnSpec.resistedTravel(-1000, 400);
      expect(
        travel.abs(),
        lessThanOrEqualTo(400 + ReaderPageTurnSpec.overscroll),
        reason: '越界位移封顶',
      );
      expect(travel.abs(), greaterThan(400), reason: '越界仍要有可见的位移（能看出顶住了）');
      expect(
        travel,
        greaterThanOrEqualTo(-400 - ReaderPageTurnSpec.overscroll),
        reason: '不得越过封顶值',
      );
    });

    test('视口宽为 0 时不产生位移（布局未就绪不炸）', () {
      expect(ReaderPageTurnSpec.resistedTravel(-100, 0), 0);
    });
  });

  group('跟手拖拽判定', () {
    test('progress：位移 1:1 映射到翻页进度（左滑为正 = 下一页）', () {
      final drag = ReaderPageTurnDrag()..update(-100);
      expect(
        drag.progress(400),
        closeTo(0.25, 1e-9),
        reason: '左滑 100px / 视口 400px = 0.25 页',
      );
      final back = ReaderPageTurnDrag()..update(100);
      expect(back.progress(400), closeTo(-0.25, 1e-9), reason: '右滑 = 上一页');
    });

    test('未过阈值 → 取消（弹回原页）', () {
      final drag = ReaderPageTurnDrag()..update(-50);
      expect(
        drag.decide(400),
        ReaderPageTurnOutcome.cancel,
        reason: '50px < 阈值 100px（400×25%）',
      );
    });

    test('左滑过阈值 → 下一页', () {
      final drag = ReaderPageTurnDrag()..update(-150);
      expect(drag.decide(400), ReaderPageTurnOutcome.next);
    });

    test('右滑过阈值 → 上一页', () {
      final drag = ReaderPageTurnDrag()..update(150);
      expect(drag.decide(400), ReaderPageTurnOutcome.previous);
    });

    test('累积位移：多次 move 累加到同一判定里', () {
      final drag = ReaderPageTurnDrag()
        ..update(-60)
        ..update(-60);
      expect(drag.dx, -120);
      expect(drag.decide(400), ReaderPageTurnOutcome.next);
    });

    test('reset 后从零重新跟手', () {
      final drag = ReaderPageTurnDrag()..update(-300);
      drag.reset();
      expect(drag.dx, 0);
      expect(drag.progress(400), 0);
      expect(drag.decide(400), ReaderPageTurnOutcome.cancel);
    });
  });
}
