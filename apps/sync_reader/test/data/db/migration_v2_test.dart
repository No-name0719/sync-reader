/// schemaVersion 1 → 2 迁移测试（2026-10-28，M4：reading_days / book_groups /
/// books.group_id，只增不删，docs/05 §6）。
///
/// 注：schemaVersion 已随 v1.1 重设计批 1 升到 3（新增 local_only_books /
/// app_settings），并随分组云端同步升到 4（新增 group_sync_state 表 +
/// book_groups.deleted/deleted_at 列）。本测试从 **v1 库**直接升级到 4：
/// drift 依次执行 `onUpgrade(1, 4)`，先补 v2 的表/列，再补 v3/v4 的新表——
/// 多条迁移路径都被覆盖（v2→v3 见 `migration_v3_test.dart`，v3→v4 见
/// `migration_v4_test.dart`）。
///
/// 机制说明（如何真实走到 onUpgrade 1→3）：
/// 1. drift 的 `NativeDatabase` 在打开原生 SQLite 连接时先执行 [DatabaseSetup]
///    回调，然后才读 `PRAGMA user_version` 决定路径（drift runtime/executor/
///    helpers/engines.dart `_runMigrations`）：user_version=0 视为新建库走
///    onCreate（`m.createAll()`）；0 < v < schemaVersion 走 onUpgrade(v, now)。
/// 2. 本测试在 setup 回调里手写 docs/05 §5 的 **v1 全部表结构**（v2 之前：
///    books 无 group_id，也没有 reading_days / book_groups）、插入一行 v1
///    书籍数据，并置 `PRAGMA user_version = 1`。
/// 3. 随后 `AppDatabase.forTesting(...)` 的首个查询触发打开：drift 读到
///    user_version=1 < 4 → 走 `onUpgrade(m, 1, 4)`（不会触发 createAll），
///    迁移完成后由 drift 把 user_version 置为 4，再执行 beforeOpen。
///    因此"打开无异常 + 新表/新列存在 + 旧数据完好"即证明迁移真实发生。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

/// v1 时代的旧书 id（ULID 形态占位，仅测试用）。
const _v1BookId = '01JABCDEFGB0OKV1DATA00000X';

/// docs/05 §5 v1 DDL（与 v1 版 drift 生成结构一致：books 无 group_id，
/// 无 reading_days / book_groups）。
const _v1Ddl = [
  'CREATE TABLE books ('
      'book_id TEXT PRIMARY KEY, '
      'title TEXT NOT NULL, '
      "author TEXT NOT NULL DEFAULT '', "
      'format TEXT NOT NULL, '
      'file_name TEXT NOT NULL, '
      'local_path TEXT, '
      'content_hash TEXT NOT NULL, '
      'size_bytes INTEGER NOT NULL, '
      'cover_path TEXT, '
      'toc_fingerprint TEXT NOT NULL, '
      'added_at INTEGER NOT NULL, '
      'last_read_at INTEGER, '
      'total_seconds INTEGER NOT NULL DEFAULT 0)',
  'CREATE INDEX idx_books_last_read ON books (last_read_at)',
  'CREATE INDEX idx_books_title ON books (title)',
  'CREATE TABLE progress ('
      'book_id TEXT PRIMARY KEY REFERENCES books(book_id) ON DELETE CASCADE, '
      'locator_json TEXT NOT NULL, '
      'percent REAL NOT NULL, '
      'updated_at INTEGER NOT NULL, '
      'dirty INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE sync_state ('
      'book_id TEXT NOT NULL, '
      'backend_key TEXT NOT NULL, '
      'base_rev INTEGER NOT NULL, '
      'remote_etag TEXT, '
      'last_synced_meta_json TEXT, '
      'last_synced_at INTEGER NOT NULL, '
      'PRIMARY KEY (book_id, backend_key))',
  'CREATE TABLE deleted_books ('
      'book_id TEXT PRIMARY KEY, '
      'deleted_at INTEGER NOT NULL, '
      'pushed INTEGER NOT NULL DEFAULT 0, '
      'content_hash TEXT NOT NULL)',
  'CREATE TABLE sync_cursor ('
      'backend_key TEXT PRIMARY KEY, '
      'changes_cursor TEXT, '
      'meta_listing_etag TEXT, '
      'last_full_sync_at INTEGER, '
      'quota_up_bytes INTEGER NOT NULL DEFAULT 0, '
      'quota_down_bytes INTEGER NOT NULL DEFAULT 0, '
      'quota_month TEXT)',
  'CREATE TABLE reader_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  'CREATE TABLE sync_queue ('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, '
      'book_id TEXT NOT NULL, '
      'op TEXT NOT NULL, '
      'enqueued_at INTEGER NOT NULL, '
      'attempts INTEGER NOT NULL DEFAULT 0)',
];

/// v1 时代的旧数据：一本书 + 一条进度。
const _v1Inserts = [
  "INSERT INTO books (book_id, title, author, format, file_name, local_path, "
      "content_hash, size_bytes, cover_path, toc_fingerprint, added_at, "
      "last_read_at, total_seconds) VALUES "
      "('$_v1BookId', '旧书', '旧作者', 'txt', 'old.txt', '/tmp/old.txt', "
      "'sha256:old', 42, NULL, 'tfp:0000000000000000', 1700000000000, "
      "1700000100000, 123)",
  "INSERT INTO progress (book_id, locator_json, percent, updated_at, dirty) "
      "VALUES ('$_v1BookId', '{\"type\":\"raw\",\"ratio\":0.5}', 0.5, "
      "1700000100000, 0)",
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          // 与生产 beforeOpen 一致打开外键（迁移中 ADD COLUMN 带 REFERENCES
          // 合法：group_id 默认值为 NULL）。
          rawDb.execute('PRAGMA foreign_keys=ON');
          for (final sql in _v1Ddl) {
            rawDb.execute(sql);
          }
          for (final sql in _v1Inserts) {
            rawDb.execute(sql);
          }
          // 关键：标记为 v1 库 → drift 打开时走 onUpgrade(1→2) 而非 onCreate。
          rawDb.execute('PRAGMA user_version = 1');
        },
      ),
    );
  });

  tearDown(() async => db.close());

  test('以 user_version=1 打开：走 onUpgrade(1→4)，新表/新列就位，旧数据完好', () async {
    // 首个查询触发打开路径；若迁移抛错这里直接失败。
    final versionRow = await db.customSelect('PRAGMA user_version').getSingle();
    // drift 迁移成功后已把版本写为 3（证明确实发生了迁移而非 onCreate）。
    expect(versionRow.data['user_version'], 4);

    // v2 新增表存在。
    final tables =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table'",
                )
                .get())
            .map((row) => row.data['name'] as String)
            .toSet();
    expect(tables, containsAll(<String>['reading_days', 'book_groups']));
    // v3 新增表存在（只增不删）。
    expect(tables, containsAll(<String>['local_only_books', 'app_settings']));
    // v4 新增表存在（分组云端同步，只增不删）。
    expect(tables, contains('group_sync_state'));

    // books.group_id 列存在且可空（未分组书为 NULL）。
    final columns = (await db.customSelect('PRAGMA table_info(books)').get())
        .map((row) => row.data['name'] as String)
        .toList();
    expect(columns, contains('group_id'));

    // v1 旧数据完好可读（books 行 + progress 行）。
    final book = await db.booksDao.getById(_v1BookId);
    expect(book, isNotNull);
    expect(book!.title, '旧书');
    expect(book.author, '旧作者');
    expect(book.totalSeconds, 123);
    expect(book.groupId, isNull); // 迁移新增列默认未分组
    final progress = await db.progressDao.getByBookId(_v1BookId);
    expect(progress, isNotNull);
    expect(progress!.percent, 0.5);
    expect(progress.dirty, isFalse);
  });

  test('迁移后的新表/新列真实可用', () async {
    // reading_days：按天累加可用。
    await db.readingDaysDao.addSeconds(_v1BookId, '2026-10-28', 60);
    expect(await db.readingDaysDao.totalSeconds(_v1BookId), 60);

    // book_groups + books.group_id：建组、入组、删组置回 NULL 全链路。
    final group = await db.bookGroupsDao.createGroup('迁移验证');
    await db.booksDao.setGroup(_v1BookId, group.groupId);
    expect((await db.booksDao.getById(_v1BookId))!.groupId, group.groupId);
    await db.bookGroupsDao.deleteGroup(group.groupId);
    expect((await db.booksDao.getById(_v1BookId))!.groupId, isNull);
  });

  test('schemaVersion == 4（docs/05 §6）', () => expect(db.schemaVersion, 4));
}
