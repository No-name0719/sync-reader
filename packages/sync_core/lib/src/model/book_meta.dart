import 'dart:convert';

import '../internal/json_fields.dart';
import 'locator.dart';

/// 当前元数据 schema 版本（docs/05 §6）。演进规则：只加字段、不删字段、
/// 读方容忍未知字段；写回时保留原 `schemaVersion` 不变。
const int kCurrentSchemaVersion = 1;

/// 每书元数据，与云端 `meta/{bookId}.json` 一一对应（docs/05 §2/§3）。
///
/// 冲突定序：`(rev, updatedAt, deviceId)` 三元组 LWW，大者胜（docs/04 §6.2）。
/// `fromJson` 执行严格校验，失败抛 [FormatException]——调用方将该书包记为
/// `Corruption` 并跳过，不得阻塞全库同步（docs/05 §6）。
class BookMeta {
  const BookMeta({
    required this.schemaVersion,
    required this.bookId,
    required this.rev,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.deletedAt,
    this.dedupOf,
    required this.book,
    this.progress,
    required this.reading,
    this.annotations = const [],
    this.extra = const {},
    this.groupId,
  });

  final int schemaVersion;
  final String bookId; // ULID，= 文件名主干
  final int rev; // 写端单调递增，≥1
  final String deviceId; // 最后写入设备（决胜第三位）
  final String deviceName; // 展示用
  final DateTime createdAt;
  final DateTime updatedAt; // 决胜第二位（毫秒精度）
  final bool deleted; // tombstone 标记
  final DateTime? deletedAt; // GC 依据（90 天，docs/04 §7.3）
  final String? dedupOf; // 去重指向保留的 bookId（docs/05 §4.3）
  final BookInfo book;
  final ReadingProgress? progress; // 未读过为 null
  final ReadingStats reading;
  final List<Object?> annotations; // v1 恒为空数组（v2 批注占位）
  final Map<String, Object?> extra; // 向前兼容扩展区，读方容忍未知键

  /// 所属分组 id（FR-107，docs/05 §2.2）：null = 未分组。
  ///
  /// **可选字段**（只增不删，docs/05 §6）：旧版本客户端读到该字段会忽略
  /// （`fromJson` 只取已知键），写回时丢失分组归属 = 降级为"未分组"，
  /// 不破坏既有书籍同步语义。
  final String? groupId;

  bool get isTombstone => deleted;

  /// 冲突比较键：先 rev，再 updatedAt，再 deviceId 字典序（docs/04 §6.2）。
  int compareTo(BookMeta other) {
    if (rev != other.rev) return rev.compareTo(other.rev);
    final byTime = updatedAt.compareTo(other.updatedAt);
    if (byTime != 0) return byTime;
    return deviceId.compareTo(other.deviceId);
  }

  /// 生成本书的 tombstone 形态（同一文件名、`deleted=true`；
  /// `book` 保留供游离文件重关联比对 hash，docs/05 §2）。
  BookMeta toTombstone({
    required DateTime deletedAt,
    required String deviceId,
    required String deviceName,
  }) {
    return BookMeta(
      schemaVersion: schemaVersion,
      bookId: bookId,
      rev: rev + 1,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: createdAt,
      updatedAt: updatedAt,
      deleted: true,
      deletedAt: deletedAt,
      dedupOf: dedupOf,
      book: book,
      progress: progress,
      reading: reading,
      annotations: annotations,
      extra: extra,
      groupId: groupId,
    );
  }

  factory BookMeta.fromJson(Map<String, Object?> json) {
    final schemaVersion = requireInt(json, 'schemaVersion');
    if (schemaVersion < 1) {
      throw const FormatException('schemaVersion 必须 ≥ 1');
    }
    final deleted = json['deleted'] == true;
    return BookMeta(
      schemaVersion: schemaVersion,
      bookId: requireString(json, 'bookId'),
      rev: requireRev(json),
      deviceId: requireString(json, 'deviceId'),
      deviceName: requireString(json, 'deviceName'),
      createdAt: requireTime(json, 'createdAt'),
      updatedAt: requireTime(json, 'updatedAt'),
      deleted: deleted,
      deletedAt: deleted ? optionalTime(json, 'deletedAt') : null,
      dedupOf: json['dedupOf'] is String ? json['dedupOf'] as String : null,
      book: BookInfo.fromJson(requireMap(json, 'book')),
      progress: json['progress'] == null
          ? null
          : ReadingProgress.fromJson(requireMap(json, 'progress')),
      reading: ReadingStats.fromJson(requireMap(json, 'reading')),
      annotations: json['annotations'] is List
          ? (json['annotations'] as List).toList()
          : const [],
      extra: json['extra'] is Map
          ? (json['extra'] as Map).cast<String, Object?>()
          : const {},
      // 可选字段：缺失容忍（只增不删，读方容忍未知/缺失键）。
      groupId: json['groupId'] is String ? json['groupId'] as String : null,
    );
  }

  factory BookMeta.fromJsonString(String source) =>
      BookMeta.fromJson((jsonDecode(source) as Map).cast<String, Object?>());

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'bookId': bookId,
    'rev': rev,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'deleted': deleted,
    'deletedAt': deletedAt?.toUtc().toIso8601String(),
    'dedupOf': dedupOf,
    'book': book.toJson(),
    'progress': progress?.toJson(),
    'reading': reading.toJson(),
    'annotations': List<Object?>.of(annotations),
    'extra': Map<String, Object?>.of(extra),
    'groupId': groupId,
  };

  String toJsonString() => jsonEncode(toJson());

  @override
  String toString() =>
      'BookMeta($bookId rev=$rev${deleted ? ' [tombstone]' : ''})';
}

/// 静态书信息（docs/05 §3.2）。`contentHash` 不可变：同一 bookId 下 hash 变化
/// 必须伴随显式"替换文件"流程，否则视为损坏（docs/05 §6 不变式 3）。
class BookInfo {
  const BookInfo({
    required this.title,
    required this.author,
    required this.format,
    required this.fileName,
    required this.contentHash,
    required this.sizeBytes,
    this.language,
    this.coverHash,
    required this.tocFingerprint,
  });

  final String title;
  final String author; // 可为空串
  final String format; // txt|epub|md|pdf，扩展格式自由字符串
  final String fileName; // 原始文件名（恢复导出用）
  final String contentHash; // `sha256:<hex>`
  final int sizeBytes;
  final String? language; // ISO 639-1
  final String? coverHash; // 封面不上云，hash 用于变化检测
  final String tocFingerprint; // 目录指纹，不一致时进度降级为 percent

  factory BookInfo.fromJson(Map<String, Object?> json) => BookInfo(
    title: requireString(json, 'title'),
    author: json['author'] is String ? json['author'] as String : '',
    format: requireString(json, 'format'),
    fileName: requireString(json, 'fileName'),
    contentHash: requireString(json, 'contentHash'),
    sizeBytes: requireInt(json, 'sizeBytes'),
    language: json['language'] is String ? json['language'] as String : null,
    coverHash: json['coverHash'] is String ? json['coverHash'] as String : null,
    tocFingerprint: requireString(json, 'tocFingerprint'),
  );

  Map<String, Object?> toJson() => {
    'title': title,
    'author': author,
    'format': format,
    'fileName': fileName,
    'contentHash': contentHash,
    'sizeBytes': sizeBytes,
    'language': language,
    'coverHash': coverHash,
    'tocFingerprint': tocFingerprint,
  };
}

/// 阅读进度（docs/05 §3.3）。`percent ∈ [0,1]`（docs/05 §6 不变式 4）。
class ReadingProgress {
  const ReadingProgress({
    required this.locator,
    required this.percent,
    required this.updatedAt,
  }) : assert(percent >= 0.0 && percent <= 1.0, 'percent 必须在 [0,1] 内');

  final Locator locator;
  final double percent; // 0.0-1.0，跨格式统一展示用
  final DateTime updatedAt;

  factory ReadingProgress.fromJson(Map<String, Object?> json) {
    final percent = requireNum(json, 'percent');
    if (percent < 0.0 || percent > 1.0) {
      throw FormatException('percent 越界: $percent');
    }
    return ReadingProgress(
      locator: Locator.fromJson(requireMap(json, 'locator')),
      percent: percent,
      updatedAt: requireTime(json, 'updatedAt'),
    );
  }

  Map<String, Object?> toJson() => {
    'locator': locator.toJson(),
    'percent': percent,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// 阅读统计（docs/05 §3.4）。冲突时 `totalSeconds` 求和合并、
/// `lastReadAt` 取最大值（docs/04 §6.3）。
class ReadingStats {
  const ReadingStats({required this.totalSeconds, required this.lastReadAt});

  final int totalSeconds;
  final DateTime lastReadAt;

  factory ReadingStats.fromJson(Map<String, Object?> json) => ReadingStats(
    totalSeconds: requireInt(json, 'totalSeconds'),
    lastReadAt: requireTime(json, 'lastReadAt'),
  );

  Map<String, Object?> toJson() => {
    'totalSeconds': totalSeconds,
    'lastReadAt': lastReadAt.toUtc().toIso8601String(),
  };
}
