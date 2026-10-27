/// 展示层格式化工具（书库/详情页共用）：字节/时长/时间/百分比/哈希缩略。
/// 纯函数，无副作用，可单测。
library;

import 'package:intl/intl.dart';

/// 字节数人性化：`980 B` / `12.3 KB` / `4.56 MB` / `1.2 GB`。
String humanizeBytes(int bytes) {
  if (bytes < 0) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 100 || unit == 0
      ? value.round().toString()
      : value.toStringAsFixed(value >= 10 ? 1 : 2);
  return '$text ${units[unit]}';
}

/// 秒数人性化（累计阅读时长）：`42 秒` / `35 分钟` / `3 小时 12 分钟` / `2 天 5 小时`。
String humanizeDuration(int totalSeconds) {
  if (totalSeconds < 0) return '-';
  if (totalSeconds < 60) return '$totalSeconds 秒';
  final minutes = totalSeconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  if (hours < 24) {
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
  }
  final days = hours ~/ 24;
  final restHours = hours % 24;
  return restHours == 0 ? '$days 天' : '$days 天 $restHours 小时';
}

/// epoch 毫秒 → `yyyy-MM-dd HH:mm`（本地时区）。
String formatEpochMs(int? epochMs) {
  if (epochMs == null || epochMs <= 0) return '-';
  return DateFormat('yyyy-MM-dd HH:mm')
      .format(DateTime.fromMillisecondsSinceEpoch(epochMs));
}

/// 阅读比例 0.0–1.0 → `42%`（四舍五入，钳制 0–100）。
String formatPercent(double ratio) {
  final percent = (ratio.clamp(0.0, 1.0) * 100).round();
  return '$percent%';
}

/// 内容哈希缩略展示：`sha256:01234567…`（前 8 个 hex + 省略号）。
String shortenHash(String hash) {
  final colon = hash.indexOf(':');
  if (colon < 0) {
    return hash.length <= 8 ? hash : '${hash.substring(0, 8)}…';
  }
  final prefix = hash.substring(0, colon + 1);
  final body = hash.substring(colon + 1);
  if (body.length <= 8) return hash;
  return '$prefix${body.substring(0, 8)}…';
}
