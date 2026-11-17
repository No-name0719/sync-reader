/// schemaVersion 2 → 3 迁移测试（2026-10-28，v1.1 重设计批 1：
/// `local_only_books` / `app_settings` 两张纯本地表，只增不删，docs/05 §6）。
///
/// 机制说明（如何真实走到 onUpgrade 2→3）：
/// 1. drift 打开原生 SQLite 连接时先执行 [DatabaseSetup] 回调，再读
///    `PRAGMA user_version` 决定路径：user_version=0 视为新建库走 onCreate；
///    0 < v < schemaVersion 走 onUpgrade(v, now)。
/// 2. 本测试在 setup 回调里手写 docs/05 §5 的 **v2 全部表结构**（books 带
///    group_id，含 reading_days / book_groups，不含 v3 的两张新表），插入
///    一行 v2 书籍数据，并置 `PRAGMA user_version = 2`。
/// 3. `AppDatabase.forTesting(...)` 的首个查询触发打开：drift 读到
///    user_version=2 < 3 → 走 `onUpgrade(m, 2, 3)`（不会触发 createAll），
///    迁移完成后由 drift 把 user_version 置为 3。
///    "打开无异常 + 新表存在 + 旧数据完好"即证明 2→3 真实发生。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

/// v2 时代的旧书 id（ULID 形态占位，仅测试用）。
const _v2BookId = '01JABCDEFGB0OKV2DATA00000Y';

/// docs/05 §5 v2 DDL（v3 之前：无 local_only_books / app_settings）。
const _v2Ddl = [
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
      'total_seconds INTEGER NOT NULL DEFAULT 0, '
      'group_id TEXT REFERENCES book_groups(group_id) ON DELETE SET NULL)',
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
  'CREATE TABLE reading_days ('
      'book_id TEXT NOT NULL REFERENCES books(book_id) ON DELETE CASCADE, '
      'day TEXT NOT NULL, '
      'seconds INTEGER NOT NULL DEFAULT 0, '
      'PRIMARY KEY (book_id, day))',
  'CREATE TABLE book_groups ('
      'group_id TEXT PRIMARY KEY, '
      'name TEXT NOT NULL, '
      'sort_order INTEGER NOT NULL DEFAULT 0, '
      'created_at INTEGER NOT NULL)',
];

/// v2 时代的旧数据：一本书 + 一条进度 + 一个分组。
const _v2Inserts = [
  "INSERT INTO books (book_id, title, author, format, file_name, local_path, "
      "content_hash, size_bytes, cover_path, toc_fingerprint, added_at, "
      "last_read_at, total_seconds, group_id) VALUES "
      "('$_v2BookId', 'v2旧书', '旧作者', 'txt', 'old.txt', '/tmp/old.txt', "
      "'sha256:old', 42, NULL, 'tfp:0000000000000000', 1700000000000, "
      "1700000100000, 123, NULL)",
  "INSERT INTO progress (book_id, locator_json, percent, updated_at, dirty) "
      "VALUES ('$_v2BookId', '{\"type\":\"raw\",\"ratio\":0.5}', 0.5, "
      "1700000100000, 0)",
  "INSERT INTO book_groups (group_id, name, sort_order, created_at) VALUES "
      "('01JGROUP0000000000000000', '旧分组', 0, 1700000000000)",
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys=ON');
          for (final sql in _v2Ddl) {
            rawDb.execute(sql);
          }
          for (final sql in _v2Inserts) {
            rawDb.execute(sql);
          }
          // 关键：标记为 v2 库 → drift 打开时走 onUpgrade(2→3) 而非 onCreate。
          rawDb.execute('PRAGMA user_version = 2');
        },
      ),
    );
  });

  tearDown(() async => db.close());

  test('以 user_version=2 打开：走 onUpgrade(2→4)，新表就位，旧数据完好', () async {
    final versionRow = await db.customSelect('PRAGMA user_version').getSingle();
    expect(versionRow.data['user_version'], 4);

    final tables =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table'",
                )
                .get())
            .map((row) => row.data['name'] as String)
            .toSet();
    expect(tables, containsAll(<String>['local_only_books', 'app_settings']));
    // v4 新增表存在（分组云端同步，只增不删）。
    expect(tables, contains('group_sync_state'));
    // 只增不删：v2 的表全部还在。
    expect(
      tables,
      containsAll(<String>[
        'books',
        'progress',
        'sync_state',
        'deleted_books',
        'sync_cursor',
        'reader_settings',
        'sync_queue',
        'reading_days',
        'book_groups',
      ]),
    );

    // v2 旧数据完好可读。
    final book = await db.booksDao.getById(_v2BookId);
    expect(book, isNotNull);
    expect(book!.title, 'v2旧书');
    expect(book.totalSeconds, 123);
    final progress = await db.progressDao.getByBookId(_v2BookId);
    expect(progress, isNotNull);
    expect(progress!.percent, 0.5);
    final groups = await db.bookGroupsDao.allGroups();
    expect(groups.map((g) => g.name), contains('旧分组'));
  });

  test('迁移后的新表真实可用', () async {
    // local_only_books：标记/判定可用。
    await db.localOnlyBooksDao.markLocalOnly(_v2BookId);
    expect(await db.localOnlyBooksDao.isLocalOnly(_v2BookId), isTrue);
    expect(await db.localOnlyBooksDao.countLocalOnly(), 1);
    await db.localOnlyBooksDao.clearLocalOnly(_v2BookId);
    expect(await db.localOnlyBooksDao.isLocalOnly(_v2BookId), isFalse);

    // app_settings：key-value 可写可读。
    await db
        .into(db.appSettings)
        .insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: 'accent', value: '"ochre"'),
        );
    final row = await db.select(db.appSettings).getSingle();
    expect(row.value, '"ochre"');
  });

  test('schemaVersion == 4（docs/05 §6）', () => expect(db.schemaVersion, 4));
}
