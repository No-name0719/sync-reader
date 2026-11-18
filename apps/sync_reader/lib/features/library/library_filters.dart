/// 书库两层筛选的纯函数核心（docs/10 §4.2 A4/A18，Q20 四态分区）。
///
/// 第一层 · 状态 chip（互斥单选）：全部 / 已同步 / 仅本地 / 仅云端；
/// 第二层 · 分组下拉：全部分组 / 未分组 / 各分组。两层同时生效取交集，
/// 计数为分面计数（状态层计数在当前分组筛选下统计，分组层计数在当前
/// 状态筛选下统计，互相联动）。
///
/// 本文件只依赖数据行与集合入参，不触碰 Riverpod / widget，可单测。
/// UI 层「云端有」的近似 = `sync_state` 有该书行（baseRev 存在）且不在
/// 本轮 cloudMissingMarks 里。
library;

import '../../../data/db/app_database.dart';

/// 第一层筛选取值（互斥单选；`all` = 不过滤）。
enum LibraryStatusFilter {
  all('全部'),
  synced('已同步'),
  localOnly('仅本地'),
  cloudOnly('仅云端');

  const LibraryStatusFilter(this.label);

  /// chip 上的中文文案。
  final String label;
}

/// 单本书的状态桶（Q20：四态互斥、计数不重叠；「全部」不是桶）。
enum LibraryStatusBucket {
  /// 云端有 + 本地有正文。
  synced,

  /// 云端没有 + 本地有正文（含导入时选「不上传」与「从云端移除」两来源）。
  localOnly,

  /// 云端有 + 本地没有正文（真正的云端占位书）。
  ///
  /// 本地已删除的书**不在书库里**（删除即移出书库，docs/10 §4.7b），
  /// 故这一桶不再混入「已删除」的书。
  cloudOnly,
}

/// 单本书状态桶判定（docs/10 §4.2 UI 层规则，按优先级依次短路）：
///
/// 1. `localOnlyIds` 命中，或（本地有正文 且 无 baseRev），或（在
///    `cloudMissingMarks` 且本地有正文）→ 仅本地；
/// 2. `localPath` 为 NULL → 仅云端（真正的云端占位书）；
/// 3. 其余（本地有正文 且 有 baseRev 且不在 cloudMissing）→ 已同步。
///
/// [cloudBaseIds] = `sync_state` 有行的 bookId（baseRev 存在）；
/// [cloudMissingMarks] = 最近一轮同步判定「云端缺失」的书（内存集合）。
LibraryStatusBucket classifyBookStatus(
  Book book, {
  required Set<String> localOnlyIds,
  required Set<String> cloudBaseIds,
  required Set<String> cloudMissingMarks,
}) {
  final hasContent = (book.localPath ?? '').isNotEmpty;
  if (localOnlyIds.contains(book.bookId) ||
      (hasContent && !cloudBaseIds.contains(book.bookId)) ||
      (cloudMissingMarks.contains(book.bookId) && hasContent)) {
    return LibraryStatusBucket.localOnly;
  }
  if (!hasContent) {
    return LibraryStatusBucket.cloudOnly;
  }
  return LibraryStatusBucket.synced;
}

/// 状态层筛选是否命中（`all` 恒真）。
bool matchesStatusFilter(
  LibraryStatusFilter filter,
  LibraryStatusBucket bucket,
) => switch (filter) {
  LibraryStatusFilter.all => true,
  LibraryStatusFilter.synced => bucket == LibraryStatusBucket.synced,
  LibraryStatusFilter.localOnly => bucket == LibraryStatusBucket.localOnly,
  LibraryStatusFilter.cloudOnly => bucket == LibraryStatusBucket.cloudOnly,
};

/// 状态层分面计数：在 [groupMatch]（第二层分组筛选）下各状态的本数。
Map<LibraryStatusFilter, int> statusFacetCounts(
  List<Book> books, {
  required Set<String> localOnlyIds,
  required Set<String> cloudBaseIds,
  required Set<String> cloudMissingMarks,
  required bool Function(Book book) groupMatch,
}) {
  final counts = <LibraryStatusFilter, int>{};
  for (final filter in LibraryStatusFilter.values) {
    counts[filter] = groupFacetCount(
      books,
      status: filter,
      localOnlyIds: localOnlyIds,
      cloudBaseIds: cloudBaseIds,
      cloudMissingMarks: cloudMissingMarks,
      groupMatch: groupMatch,
    );
  }
  return counts;
}

/// 给定状态筛选下，[groupMatch] 分组的本数（分组下拉的分面计数）。
int groupFacetCount(
  List<Book> books, {
  required LibraryStatusFilter status,
  required Set<String> localOnlyIds,
  required Set<String> cloudBaseIds,
  required Set<String> cloudMissingMarks,
  required bool Function(Book book) groupMatch,
}) {
  var n = 0;
  for (final book in books) {
    if (!groupMatch(book)) continue;
    final bucket = classifyBookStatus(
      book,
      localOnlyIds: localOnlyIds,
      cloudBaseIds: cloudBaseIds,
      cloudMissingMarks: cloudMissingMarks,
    );
    if (matchesStatusFilter(status, bucket)) n++;
  }
  return n;
}

/// 上行流量预估文案（Q18 导入确认弹窗）：`预计上行 42.6 MB · 坚果云免费额度
/// 1 GB / 月`。MB 保留 1 位小数，≥1 GB 换算为 GB（同样 1 位小数）。
String uploadEstimateText(int totalBytes) {
  const mb = 1024 * 1024;
  const gb = 1024 * mb;
  final size = totalBytes >= gb
      ? '${(totalBytes / gb).toStringAsFixed(1)} GB'
      : '${(totalBytes / mb).toStringAsFixed(1)} MB';
  return '预计上行 $size · 坚果云免费额度 1 GB / 月';
}
