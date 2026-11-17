/// meta JSON 的严格字段校验助手（docs/05 §3 / §6）。
///
/// 语义约定（书籍与分组共用）：
/// - 必填字段缺失或类型不符 → 抛 [FormatException]，调用方把该条目记为
///   `Corruption` 并跳过，**不阻塞全库同步**（docs/05 §6 校验行）；
/// - 可选字段缺失 → 容忍（读方必须容忍未知/缺失字段，docs/05 §6 演进规则）。
library;

/// 必填 int。
int requireInt(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is int) return v;
  throw FormatException('$key 必须为 int，实际: $v');
}

/// 必填 num（转 double）。
double requireNum(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is num) return v.toDouble();
  throw FormatException('$key 必须为 num，实际: $v');
}

/// 必填非空 String。
String requireString(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is String && v.isNotEmpty) return v;
  throw FormatException('$key 必须为非空 String，实际: $v');
}

/// 必填 rev（≥1，写端单调递增）。
int requireRev(Map<String, Object?> json) {
  final rev = requireInt(json, 'rev');
  if (rev >= 1) return rev;
  throw FormatException('rev 必须 ≥ 1，实际: $rev');
}

/// 必填 ISO-8601 时间。
DateTime requireTime(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is String) {
    return DateTime.parse(v);
  }
  throw FormatException('$key 必须为 ISO-8601 字符串，实际: $v');
}

/// 可选 ISO-8601 时间（缺失 → null）。
DateTime? optionalTime(Map<String, Object?> json, String key) {
  final v = json[key];
  return v is String ? DateTime.parse(v) : null;
}

/// 必填 object。
Map<String, Object?> requireMap(Map<String, Object?> json, String key) {
  final v = json[key];
  if (v is Map) return v.cast<String, Object?>();
  throw FormatException('$key 必须为 object，实际: $v');
}
