/// 应用数据库（docs/05 §5）：schemaVersion 5，WAL 模式。
///
/// - 生产：drift_flutter 的 [driftDatabase]（懒加载 + 后台 isolate）；
/// - 测试：[AppDatabase.forTesting] 注入内存 [NativeDatabase]。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'daos/app_settings_dao.dart';
import 'daos/book_groups_dao.dart';
import 'daos/books_dao.dart';
import 'daos/local_only_books_dao.dart';
import 'daos/progress_dao.dart';
import 'daos/reading_days_dao.dart';
import 'daos/reader_settings_dao.dart';
import 'daos/sync_queue_dao.dart';
import 'tables.dart';

part 'app_database.g.dart';

@DriftDatabase(
  tables: [
    Books,
    Progress,
    SyncState,
    DeletedBooks,
    SyncCursor,
    ReaderSettings,
    SyncQueue,
    ReadingDays,
    BookGroups,
    LocalOnlyBooks,
    AppSettings,
    GroupSyncState,
  ],
  daos: [
    BooksDao,
    ProgressDao,
    ReaderSettingsDao,
    SyncQueueDao,
    ReadingDaysDao,
    BookGroupsDao,
    LocalOnlyBooksDao,
    AppSettingsDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  /// 生产构造：drift_flutter 懒加载连接（库名 sync_reader.db）。
  AppDatabase() : super(driftDatabase(name: 'sync_reader'));

  /// 测试构造：注入任意 QueryExecutor（通常 NativeDatabase.memory()）。
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v1 → v2（2026-10-28，M4）：新增 reading_days / book_groups 表与
      // books.group_id 列。只增不删（docs/05 §6）。
      //
      // 注：book_groups 以**当前定义**建表（含 v4 的 deleted/deleted_at 列），
      // 故 v4 分支在"本轮刚建表"时不再重复加列（否则 duplicate column）。
      var bookGroupsCreatedNow = false;
      if (from < 2) {
        // 先建被引用表，再加外键列。
        await m.createTable(readingDays);
        await m.createTable(bookGroups);
        bookGroupsCreatedNow = true;
        await m.addColumn(books, books.groupId);
      }
      // v2 → v3（2026-10-28，v1.1 重设计批 1）：新增 local_only_books
      // （仅本地标记）与 app_settings（应用级本地设置）两张纯本地表。
      // 只增不删（docs/05 §6）。
      if (from < 3) {
        await m.createTable(localOnlyBooks);
        await m.createTable(appSettings);
      }
      // v3 → v4（2026-11-17，分组云端同步）：新增 group_sync_state 表，
      // 并给 book_groups 加 deleted/deleted_at 两列（本地软删分组，行保留
      // 以便离线补推分组墓碑）。只增不删（docs/05 §6）。
      if (from < 4) {
        await m.createTable(groupSyncState);
        if (!bookGroupsCreatedNow) {
          await m.addColumn(bookGroups, bookGroups.deleted);
          await m.addColumn(bookGroups, bookGroups.deletedAt);
        }
      }
      // v4 → v5（2026-11-18，v1.4.1 删除语义变更：删除即移出书库）：
      // **纯数据迁移**（DDL 不变）。清理旧版「删正文、留元数据」语义留下的
      // 残影行：`deleted_books` 有墓碑的 `books` 行（旧版软删除保留行、只置空
      // local_path → 落进书库「未下载」区**永久显示**，云端和本地都删掉的
      // 书也一样）。新语义下「有墓碑 ⇒ 不在书库里」，故删掉这些行。
      //
      // 注：迁移在事务内执行，`PRAGMA foreign_keys`（在 beforeOpen 里开）
      // 此时尚未生效 → 外键级联不会自动触发，子表行**显式**先删。
      if (from < 5) {
        const ghostIds = 'SELECT book_id FROM deleted_books';
        await customStatement(
          'DELETE FROM progress WHERE book_id IN ($ghostIds)',
        );
        await customStatement(
          'DELETE FROM reading_days WHERE book_id IN ($ghostIds)',
        );
        await customStatement(
          'DELETE FROM local_only_books WHERE book_id IN ($ghostIds)',
        );
        await customStatement('DELETE FROM books WHERE book_id IN ($ghostIds)');
      }
    },
    beforeOpen: (details) async {
      // WAL：本地优先 + 读写并发（docs/02 §D3）；内存库该 PRAGMA 无效但不报错。
      await customStatement('PRAGMA journal_mode=WAL');
      // 外键级联（books → progress ON DELETE CASCADE）。
      await customStatement('PRAGMA foreign_keys=ON');
    },
  );

  /// 清除指定书籍的同步状态（baseRev/etag/公共祖先副本一并清除）。
  ///
  /// 「上传到云端」的前置动作（docs/10 §4.7c 实施要点 6）：diff 第 7a 行要求
  /// 「从未推送过（无 baseRev）」；曾同步过、后来被「从云端移除」的书仍有
  /// baseRev，不清就会落第 7b 行（保留本地、不推），上架不了。
  Future<void> clearBookSyncState(String bookId) async {
    await (delete(syncState)..where((s) => s.bookId.equals(bookId))).go();
  }
}
