/// schemaVersion 3 → 4 迁移测试（2026-11-17，分组云端同步 FR-107：
/// `group_sync_state` 新表 + `book_groups.deleted/deleted_at` 两列，
/// 只增不删，docs/05 §6）。
///
/// 机制说明（如何真实走到 onUpgrade 3→4）：
/// 1. drift 打开原生 SQLite 连接时先执行 [DatabaseSetup] 回调，再读
///    `PRAGMA user_version` 决定路径：user_version=0 视为新建库走 onCreate；
///    0 < v < schemaVersion 走 onUpgrade(v, now)。
/// 2. 本测试在 setup 回调里手写 docs/05 §5 的 **v3 全部表结构**（books 带
///    group_id，含 reading_days / book_groups，但 book_groups 还没有
///    deleted/deleted_at 两列，也没有 group_sync_state 表），插入 v3 旧数据，
///    并置 `PRAGMA user_version = 3`。
/// 3. `AppDatabase.forTesting(...)` 的首个查询触发打开：drift 读到
///    user_version=3 < 4 → 走 `onUpgrade(m, 3, 4)`（不会触发 createAll），
///    迁移完成后由 drift 把 user_version 置为 4。
///    "打开无异常 + 新表/新列存在 + 旧数据完好"即证明 3→4 真实发生。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

/// v3 时代的旧书 id（ULID 形态占位，仅测试用）。
const _v3BookId = '01JABCDEFGB0OKV3DATA00000Z';

/// v3 时代的旧分组 id。
const _v3GroupId = '01JGROUP000000000000000V3';

/// docs/05 §5 v3 DDL（v4 之前：book_groups 无 deleted/deleted_at，
/// 无 group_sync_state）。
const _v3Ddl = [
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
  'CREATE TABLE local_only_books ('
      'book_id TEXT PRIMARY KEY, '
      'created_at INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
];

/// v3 时代的旧数据：一本书 + 一条进度 + 一个分组（书在该分组里）。
const _v3Inserts = [
  // 先建分组再插书（books.group_id 外键指向 book_groups.group_id）。
  "INSERT INTO book_groups (group_id, name, sort_order, created_at) VALUES "
      "('$_v3GroupId', '旧分组', 0, 1700000000000)",
  "INSERT INTO books (book_id, title, author, format, file_name, local_path, "
      "content_hash, size_bytes, cover_path, toc_fingerprint, added_at, "
      "last_read_at, total_seconds, group_id) VALUES "
      "('$_v3BookId', 'v3旧书', '旧作者', 'txt', 'old.txt', '/tmp/old.txt', "
      "'sha256:old', 42, NULL, 'tfp:0000000000000000', 1700000000000, "
      "1700000100000, 123, '$_v3GroupId')",
  "INSERT INTO progress (book_id, locator_json, percent, updated_at, dirty) "
      "VALUES ('$_v3BookId', '{\"type\":\"raw\",\"ratio\":0.5}', 0.5, "
      "1700000100000, 0)",
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys=ON');
          for (final sql in _v3Ddl) {
            rawDb.execute(sql);
          }
          for (final sql in _v3Inserts) {
            rawDb.execute(sql);
          }
          // 关键：标记为 v3 库 → drift 打开时走 onUpgrade(3→4) 而非 onCreate。
          rawDb.execute('PRAGMA user_version = 3');
        },
      ),
    );
  });

  tearDown(() async => db.close());

  test('以 user_version=3 打开：走 onUpgrade(3→4)，新表/新列就位，旧数据完好', () async {
    final versionRow = await db.customSelect('PRAGMA user_version').getSingle();
    // 当前 schemaVersion 已到 5（2026-11-18，v1.4.1 数据迁移）：v3 库打开时
    // 连跑 3→4 与 4→5 两步迁移，最终 user_version = 5。
    expect(versionRow.data['user_version'], 5);

    final tables =
        (await db
                .customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table'",
                )
                .get())
            .map((row) => row.data['name'] as String)
            .toSet();
    expect(tables, contains('group_sync_state'));

    final groupColumns =
        (await db.customSelect('PRAGMA table_info(book_groups)').get())
            .map((row) => row.data['name'] as String)
            .toList();
    expect(groupColumns, containsAll(<String>['deleted', 'deleted_at']));

    // v3 旧数据完好：书仍在旧分组里，分组仍在（deleted 默认 0）。
    final book = await db.booksDao.getById(_v3BookId);
    expect(book, isNotNull);
    expect(book!.title, 'v3旧书');
    expect(book.groupId, _v3GroupId);
    final group = await db.bookGroupsDao.groupById(_v3GroupId);
    expect(group, isNotNull);
    expect(group!.name, '旧分组');
    expect(group.deleted, isFalse);
    expect(group.deletedAt, isNull);
  });

  test('迁移后的新表/新列真实可用：分组可软删 + group_sync_state 可写', () async {
    // group_sync_state：分组同步状态可写可读。
    await db
        .into(db.groupSyncState)
        .insert(
          GroupSyncStateCompanion.insert(
            groupId: _v3GroupId,
            backendKey: 'webdav',
            baseRev: 3,
            lastSyncedAt: 1700000200000,
          ),
        );
    final state = await db.select(db.groupSyncState).getSingle();
    expect(state.groupId, _v3GroupId);
    expect(state.baseRev, 3);

    // book_groups.deleted：软删分组后行保留、组内书回到未分组。
    await db.bookGroupsDao.deleteGroup(_v3GroupId);
    expect(await db.bookGroupsDao.allGroups(), isEmpty);
    final deletedRow = await db.bookGroupsDao.groupById(_v3GroupId);
    expect(deletedRow, isNotNull, reason: '软删保留行（离线补推墓碑要用）');
    expect(deletedRow!.deleted, isTrue);
    expect(deletedRow.deletedAt, isNotNull);
    final book = await db.booksDao.getById(_v3BookId);
    expect(book, isNotNull, reason: '删分组不丢书');
    expect(book!.groupId, isNull, reason: '组内书回到未分组');
  });

  test('schemaVersion == 5（docs/05 §6）', () => expect(db.schemaVersion, 5));
}
