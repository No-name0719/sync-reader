/// 应用数据库（docs/05 §5）：schemaVersion 1，WAL 模式。
///
/// - 生产：drift_flutter 的 [driftDatabase]（懒加载 + 后台 isolate）；
/// - 测试：[AppDatabase.forTesting] 注入内存 [NativeDatabase]。
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'daos/books_dao.dart';
import 'daos/progress_dao.dart';
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
  ],
  daos: [BooksDao, ProgressDao, ReaderSettingsDao, SyncQueueDao],
)
class AppDatabase extends _$AppDatabase {
  /// 生产构造：drift_flutter 懒加载连接（库名 sync_reader.db）。
  AppDatabase() : super(driftDatabase(name: 'sync_reader'));

  /// 测试构造：注入任意 QueryExecutor（通常 NativeDatabase.memory()）。
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      // WAL：本地优先 + 读写并发（docs/02 §D3）；内存库该 PRAGMA 无效但不报错。
      await customStatement('PRAGMA journal_mode=WAL');
      // 外键级联（books → progress ON DELETE CASCADE）。
      await customStatement('PRAGMA foreign_keys=ON');
    },
  );
}
