// 启动打点器（NFR-05）单测：打点取首值、达标判定、汇总输出。
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/startup_timer.dart';

void main() {
  group('StartupTimer', () {
    test('mark 记录相对起点的耗时，同名点保留首次', () {
      var t = DateTime(2026, 1, 1);
      final timer = StartupTimer(now: () => t, threshold: null);
      timer.mark('a');
      t = t.add(const Duration(milliseconds: 120));
      timer.mark('b');
      t = t.add(const Duration(milliseconds: 30));
      timer.mark('a'); // 重复打点：保留首次 0ms。
      timer.mark(StartupTimer.kFirstFrame);

      expect(timer.marks['a'], Duration.zero);
      expect(timer.marks['b'], const Duration(milliseconds: 120));
      expect(timer.marks[StartupTimer.kFirstFrame],
          const Duration(milliseconds: 150));
    });

    test('exceeded：首帧超阈值判定；未打首帧恒为 false', () {
      var t = DateTime(2026, 1, 1);
      final timer = StartupTimer(
        now: () => t,
        threshold: const Duration(milliseconds: 2500),
      );
      expect(timer.exceeded, isFalse); // 尚未打首帧。
      t = t.add(const Duration(milliseconds: 2500));
      timer.mark(StartupTimer.kFirstFrame);
      expect(timer.exceeded, isFalse); // 恰好等于阈值不算超（NFR 为 ≤）。
      t = t.add(const Duration(milliseconds: 1));
      timer.mark('after'); // 后续打点不影响已记录的首帧。
      expect(timer.exceeded, isFalse);

      t = DateTime(2026, 1, 1);
      final lateTimer = StartupTimer(
        now: () => t,
        threshold: const Duration(milliseconds: 2500),
      );
      t = t.add(const Duration(milliseconds: 2501));
      lateTimer.mark(StartupTimer.kFirstFrame);
      expect(lateTimer.exceeded, isTrue);
    });

    test('summary：按打点顺序拼接并标注达标/超限', () {
      var t = DateTime(2026, 1, 1);
      final ok = StartupTimer(
        now: () => t,
        threshold: const Duration(seconds: 3),
      )..mark(StartupTimer.kFirstFrame);
      expect(ok.summary(), contains('firstFrame=0ms'));
      expect(ok.summary(), contains('达标'));

      t = DateTime(2026, 1, 1);
      final bad = StartupTimer(
        now: () => t,
        threshold: const Duration(milliseconds: 100),
      );
      t = t.add(const Duration(milliseconds: 150));
      bad.mark(StartupTimer.kFirstFrame);
      expect(bad.summary(), contains('超限'));
    });

    test('report：首帧已打点时经 debugPrint 输出，超限走 warn 文案', () {
      final captured = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => captured.add(message ?? '');
      addTearDown(() => debugPrint = original);

      var t = DateTime(2026, 1, 1);
      final ok = StartupTimer(
        now: () => t,
        threshold: const Duration(seconds: 3),
      )..mark(StartupTimer.kFirstFrame);
      ok.report();
      expect(captured, hasLength(1));
      expect(captured.single, contains('启动打点(NFR-05)'));
      expect(captured.single, contains('达标'));

      captured.clear();
      StartupTimer(
        now: () => DateTime(2026, 1, 1),
        threshold: Duration.zero,
      ).report();
      expect(captured, isEmpty); // 未打首帧：不输出。

      captured.clear();
      final bad = StartupTimer(
        now: () => t,
        threshold: const Duration(milliseconds: 100),
      );
      t = t.add(const Duration(milliseconds: 150));
      bad.mark(StartupTimer.kFirstFrame);
      bad.report();
      expect(captured.single, contains('超限'));
    });
  });
}
