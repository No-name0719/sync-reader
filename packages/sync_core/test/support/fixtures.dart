import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';

/// 测试统一时钟基准。
final DateTime t0 = DateTime.utc(2026, 10, 26, 8, 0, 0);

/// 规整的测试 bookId：`01BOOK0000000000000N`。
String bookIdOf(int n) => '01BOOK${n.toString().padLeft(17, '0')}';

/// 规整的测试 groupId：`01GROUP000000000000N`。
String groupIdOf(int n) => '01GROUP${n.toString().padLeft(16, '0')}';

/// 构造 GroupMeta（docs/05 §2.1 字段齐备的最小合法形态）。
GroupMeta buildGroup({
  String? groupId,
  int rev = 1,
  String deviceId = '01DEVA000000000000',
  String deviceName = 'DeviceA',
  DateTime? updatedAt,
  DateTime? createdAt,
  bool deleted = false,
  DateTime? deletedAt,
  String name = '小说',
  int sortOrder = 0,
}) {
  return GroupMeta(
    schemaVersion: kGroupSchemaVersion,
    groupId: groupId ?? groupIdOf(1),
    rev: rev,
    deviceId: deviceId,
    deviceName: deviceName,
    createdAt: createdAt ?? t0,
    updatedAt: updatedAt ?? t0,
    deleted: deleted,
    deletedAt: deletedAt,
    name: name,
    sortOrder: sortOrder,
  );
}

/// `sha256:<hex>` 形式的内容哈希（与 meta.contentHash 语义一致）。
String contentHashOf(List<int> bytes) =>
    'sha256:${sha256.convert(bytes).toString()}';

/// 构造 BookMeta（docs/05 §2 字段齐备的最小合法形态）。
BookMeta buildMeta({
  String? bookId,
  int rev = 1,
  String deviceId = '01DEVA000000000000',
  String deviceName = 'DeviceA',
  DateTime? updatedAt,
  bool deleted = false,
  DateTime? deletedAt,
  String? dedupOf,
  String title = '三体',
  String format = 'txt',
  List<int> content = const [1, 2, 3],
  String? contentHash,
  int? sizeBytes,
  ReadingProgress? progress,
  int totalSeconds = 0,
  DateTime? lastReadAt,
  DateTime? createdAt,
}) {
  final bytes = content;
  return BookMeta(
    schemaVersion: kCurrentSchemaVersion,
    bookId: bookId ?? bookIdOf(1),
    rev: rev,
    deviceId: deviceId,
    deviceName: deviceName,
    createdAt: createdAt ?? t0,
    updatedAt: updatedAt ?? t0,
    deleted: deleted,
    deletedAt: deletedAt,
    dedupOf: dedupOf,
    book: BookInfo(
      title: title,
      author: '刘慈欣',
      format: format,
      fileName: '$title.$format',
      contentHash: contentHash ?? contentHashOf(bytes),
      sizeBytes: sizeBytes ?? bytes.length,
      tocFingerprint: 'tfp:${title.hashCode}',
    ),
    progress: progress,
    reading: ReadingStats(
      totalSeconds: totalSeconds,
      lastReadAt: lastReadAt ?? updatedAt ?? t0,
    ),
  );
}

/// 构造阅读进度。
ReadingProgress buildProgress({
  double percent = 0.4,
  DateTime? updatedAt,
  Locator? locator,
}) => ReadingProgress(
  locator: locator ?? const TxtLocator(chapterIndex: 1, charOffset: 100),
  percent: percent,
  updatedAt: updatedAt ?? t0,
);

/// 构造本地书籍快照。
LocalBookSnapshot buildSnapshot({
  required String bookId,
  BookMeta? meta,
  bool exists = true,
  bool dirty = false,
  bool? hasBaseRev,
  int baseRev = 0,
  bool hasLocalContent = true,
}) {
  final hasBase = hasBaseRev ?? baseRev > 0;
  return LocalBookSnapshot(
    bookId: bookId,
    meta: meta,
    exists: exists,
    dirty: dirty,
    hasBaseRev: hasBase,
    baseRev: baseRev,
    hasLocalContent: hasLocalContent,
  );
}

/// 构造远端清单 stub。
RemoteMetaStub buildStub({
  required String bookId,
  int rev = 1,
  String? etag,
  bool deleted = false,
  int? size,
}) => RemoteMetaStub(
  bookId: bookId,
  rev: rev,
  etag: etag ?? 'etag-$bookId-$rev',
  size: size,
  deleted: deleted,
);

/// 写临时正文文件，返回文件与其内容哈希。
Future<(File, String)> writeTempContent(
  Directory dir,
  String name,
  List<int> bytes,
) async {
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes);
  return (file, contentHashOf(bytes));
}

/// 定长伪随机内容（确定性）。
Uint8List deterministicBytes(int length, [int seed = 7]) {
  final out = Uint8List(length);
  var x = seed;
  for (var i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x & 0xFF;
  }
  return out;
}
