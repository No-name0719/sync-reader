/// readingDayKey 日键格式化单测（FR-208 按天统计）：补零、跨日/跨月/跨年
/// 边界、闰年；纯函数，无 IO。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/reading_day.dart';

void main() {
  group('readingDayKey', () {
    test('常规日期与单位数月/日补零到两位', () {
      expect(readingDayKey(DateTime(2026, 10, 28)), '2026-10-28');
      expect(readingDayKey(DateTime(2026, 1, 5)), '2026-01-05');
      expect(readingDayKey(DateTime(2026, 12, 31)), '2026-12-31');
      expect(readingDayKey(DateTime(2026, 2, 9, 15, 30, 45)), '2026-02-09');
    });

    test('时分秒不影响日键：23:59:59 与 00:00:00 分属两天', () {
      expect(readingDayKey(DateTime(2026, 10, 27, 23, 59, 59)), '2026-10-27');
      expect(readingDayKey(DateTime(2026, 10, 28, 0, 0, 0)), '2026-10-28');
    });

    test('跨月边界：月末最后一秒 → 次月一日', () {
      expect(readingDayKey(DateTime(2026, 4, 30, 23, 59, 59)), '2026-04-30');
      expect(readingDayKey(DateTime(2026, 5, 1)), '2026-05-01');
      expect(readingDayKey(DateTime(2026, 11, 30, 23, 59, 59)), '2026-11-30');
      expect(readingDayKey(DateTime(2026, 12, 1)), '2026-12-01');
    });

    test('跨年边界：12-31 23:59:59 → 次年 01-01', () {
      expect(readingDayKey(DateTime(2026, 12, 31, 23, 59, 59)), '2026-12-31');
      expect(readingDayKey(DateTime(2027, 1, 1)), '2027-01-01');
      expect(readingDayKey(DateTime(1999, 12, 31, 23, 59, 59)), '1999-12-31');
      expect(readingDayKey(DateTime(2000, 1, 1)), '2000-01-01');
    });

    test('闰年 2 月 29 日正常表示（平年 2 月 28 日不进位）', () {
      expect(readingDayKey(DateTime(2028, 2, 29)), '2028-02-29');
      expect(readingDayKey(DateTime(2026, 2, 28, 23, 59, 59)), '2026-02-28');
      expect(readingDayKey(DateTime(2026, 3, 1)), '2026-03-01');
    });
  });
}
