/// 两层筛选纯函数单测（lib/features/library/library_filters.dart，A4/A18）：
/// 四态分区判定（含已删除落仅云端，Q21）、两层取交集、分面计数联动、
/// 上行流量预估文案（Q18）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/library/library_filters.dart';

/// 构造书行（[cloud] = 是否插入 sync_state 行模拟「云端有」）。
BooksCompanion bookRow(
  String id, {
  String title = '书',
  String? groupId,
  String? localPath = '/books/x',
}) => BooksCompanion.insert(
  bookId: id,
  title: title,
  format: 'txt',
  fileName: '$id.txt',
  contentHash: 'sha256:$id',
  sizeBytes: 1024,
  tocFingerprint: 'tfp:0000000000000000',
  addedAt: 1000,
  localPath: Value(localPath),
  groupId: Value(groupId),
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() => db.close());

  /// 混合书集（docs/10 §4.2 四桶 + 分组）：
  /// - A1/A2 分组一：A1 已同步（云端有+正文）、A2 仅云端（未下载占位）；
  /// - B1/B2 未分组：B1 仅本地（标记表）、B2 已删除（正文删盘、本地路径空）；
  /// - C1 分组二：已同步但 dirty（仍是「已同步」桶，胶囊另表达待上传）。
  Future<void> seedBooks() async {
    final group1 = await db.bookGroupsDao.createGroup('小说');
    final group2 = await db.bookGroupsDao.createGroup('技术');
    await db.booksDao.upsertCompanion(bookRow('A1', groupId: group1.groupId));
    await db.booksDao.upsertCompanion(
      bookRow('A2', title: '占位书', groupId: group1.groupId, localPath: null),
    );
    await db.booksDao.upsertCompanion(bookRow('B1', title: '仅本地书'));
    await db.booksDao.upsertCompanion(
      bookRow('B2', title: '已删除书', localPath: null),
    );
    await db.booksDao.upsertCompanion(
      bookRow('C1', title: '待上传书', groupId: group2.groupId),
    );
    // 云端 baseRev：A1、C1（已同步桶要求）。
    for (final id in ['A1', 'C1']) {
      await db
          .into(db.syncState)
          .insert(
            SyncStateCompanion.insert(
              bookId: id,
              backendKey: 'webdav',
              baseRev: 1,
              lastSyncedAt: 1000,
            ),
          );
    }
    // 仅本地标记：B1。
    await db.localOnlyBooksDao.markLocalOnly('B1');
  }

  Future<List<Book>> loadBooks() => db.booksDao.watchBooks().first;

  final localOnly = {'B1'};
  final cloudBase = {'A1', 'C1'};
  final noMarks = const <String>{};

  bool Function(Book) groupOf(String? groupId) =>
      (Book b) => b.groupId == groupId;

  /// 「全部分组」的匹配器（不过滤）。
  bool allBooks(Book book) => true;

  test('四态分区：已同步/仅本地/仅云端，已删除落仅云端（Q21）', () async {
    await seedBooks();
    final books = await loadBooks();
    final byId = {for (final b in books) b.bookId: b};

    LibraryStatusBucket bucket(String id) => classifyBookStatus(
      byId[id]!,
      localOnlyIds: localOnly,
      cloudBaseIds: cloudBase,
      cloudMissingMarks: noMarks,
    );

    expect(bucket('A1'), LibraryStatusBucket.synced);
    expect(bucket('A2'), LibraryStatusBucket.cloudOnly, reason: '未下载占位');
    expect(bucket('B2'), LibraryStatusBucket.cloudOnly, reason: '已删除（Q21）');
    expect(bucket('B1'), LibraryStatusBucket.localOnly);
    expect(
      bucket('C1'),
      LibraryStatusBucket.synced,
      reason: 'dirty 只影响胶囊不影响分桶',
    );
  });

  test('cloudMissingMarks 命中且有正文 → 仅本地（第 7b 行「云端缺失」）', () async {
    await seedBooks();
    final books = await loadBooks();
    final byId = {for (final b in books) b.bookId: b};
    expect(
      classifyBookStatus(
        byId['A1']!,
        localOnlyIds: localOnly,
        cloudBaseIds: cloudBase,
        cloudMissingMarks: {'A1'},
      ),
      LibraryStatusBucket.localOnly,
    );
  });

  test('两层取交集 + 分面计数联动', () async {
    await seedBooks();
    final books = await loadBooks();

    // 分组筛选 = 分组一（小说）下的状态分面。
    final group1Id = (await db.bookGroupsDao.allGroups())
        .firstWhere((g) => g.name == '小说')
        .groupId;
    final countsInGroup1 = statusFacetCounts(
      books,
      localOnlyIds: localOnly,
      cloudBaseIds: cloudBase,
      cloudMissingMarks: noMarks,
      groupMatch: groupOf(group1Id),
    );
    expect(countsInGroup1[LibraryStatusFilter.all], 2);
    expect(countsInGroup1[LibraryStatusFilter.synced], 1); // A1
    expect(countsInGroup1[LibraryStatusFilter.localOnly], 0);
    expect(countsInGroup1[LibraryStatusFilter.cloudOnly], 1); // A2 占位

    // 分组筛选 = 全部分组下的状态分面。
    final countsAll = statusFacetCounts(
      books,
      localOnlyIds: localOnly,
      cloudBaseIds: cloudBase,
      cloudMissingMarks: noMarks,
      groupMatch: allBooks,
    );
    expect(countsAll[LibraryStatusFilter.all], 5);
    expect(countsAll[LibraryStatusFilter.synced], 2); // A1、C1
    expect(countsAll[LibraryStatusFilter.localOnly], 1); // B1
    expect(countsAll[LibraryStatusFilter.cloudOnly], 2); // A2、B2

    // 状态筛选 = 仅本地时各分组的分面计数（联动）。
    int groupCount(bool Function(Book) match) => groupFacetCount(
      books,
      status: LibraryStatusFilter.localOnly,
      localOnlyIds: localOnly,
      cloudBaseIds: cloudBase,
      cloudMissingMarks: noMarks,
      groupMatch: match,
    );
    expect(groupCount(allBooks), 1, reason: '全部分组下仅 B1');
    expect(groupCount(groupOf(group1Id)), 0, reason: '小说组下无仅本地');
    // 状态 = 全部时分组计数 = 组内总数。
    final allInGroup1 = groupFacetCount(
      books,
      status: LibraryStatusFilter.all,
      localOnlyIds: localOnly,
      cloudBaseIds: cloudBase,
      cloudMissingMarks: noMarks,
      groupMatch: groupOf(group1Id),
    );
    expect(allInGroup1, 2);
  });

  test('上行流量预估文案（MB 1 位小数 / ≥1GB 用 GB）', () {
    expect(
      uploadEstimateText(42 * 1024 * 1024 + 600 * 1024),
      '预计上行 42.6 MB · 坚果云免费额度 1 GB / 月',
    );
    expect(
      uploadEstimateText(1536 * 1024 * 1024),
      '预计上行 1.5 GB · 坚果云免费额度 1 GB / 月',
    );
  });
}
