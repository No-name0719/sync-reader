/// 阅读日键计算（FR-208 按天统计）：本地自然日 → 'YYYY-MM-DD' 字符串。
///
/// 纯函数、可单测；与 reading_days 表的 day 列格式约定一致
/// （lib/data/db/tables.dart `ReadingDays.day`，设备时区）。
library;

/// 某时刻所属的本地自然日键：'YYYY-MM-DD'（月/日补零到两位）。
///
/// 跨午夜/跨月/跨年边界按本地时区的年月日字段切分，不做任何时区换算。
String readingDayKey(DateTime t) {
  final month = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  return '${t.year}-$month-$day';
}
