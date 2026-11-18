/// schemaVersion 4 → 5 迁移测试（2026-11-18，v1.4.1 删除语义变更：
/// 「删除即移出书库」，docs/10 §4.7b / §9.19）。
///
/// 这是**纯数据迁移**（DDL 不变）：清理旧版「删正文、留元数据」语义留下的
/// 残影行——`deleted_books` 有墓碑的 `books` 行（旧版软删除保留行、只置空
/// `local_path` → 落进书库「未下载」区**永久显示**；云端和本地都删掉的
/// 书也一样）。新语义下「有墓碑 ⇒ 不在书库里」，故迁移把这些行删掉。
///
/// 机制说明（如何真实走到 onUpgrade 4→5）：
/// 1. drift 打开原生 SQLite 连接时先执行 [DatabaseSetup] 回调，再读
///    `PRAGMA user_version` 决定路径：user_version=0 视为新建库走 onCreate；
///    0 < v < schemaVersion 走 onUpgrade(v, now)。
/// 2. 本测试在 setup 回调里手写 docs/05 §5 的 **v4 全部表结构**，插入
///    v4 旧数据（一条"已删除但行还在"的残影 + 一条正常书），并置
///    `PRAGMA user_version = 4`。
/// 3. `AppDatabase.forTesting(...)` 的首个查询触发打开：drift 读到
///    user_version=4 < 5 → 走 `onUpgrade(m, 4, 5)`（不会触发 createAll），
///    迁移完成后由 drift 把 user_version 置为 5。
///    "残影行被清掉 + 正常书与旧数据完好"即证明 4→5 真实发生。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

/// v4 时代的旧书 id（ULID 形态占位，仅测试用）：**本地已删除的残影**。
const _ghostBookId = '01JGHOST000000000000000V4';

/// v4 时代的正常书 id（未删除，应完好保留）。
const _aliveBookId = '01JALIVE000000000000000V4';

/// docs/05 §5 v4 DDL（v5 之前：与 v3 同 + `group_sync_state` 表 +
/// `book_groups.deleted/deleted_at` 两列）。
const _v4Ddl = [
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
      'created_at INTEGER NOT NULL, '
      'deleted INTEGER NOT NULL DEFAULT 0, '
      'deleted_at INTEGER)',
  'CREATE TABLE local_only_books ('
      'book_id TEXT PRIMARY KEY, '
      'created_at INTEGER NOT NULL DEFAULT 0)',
  'CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  'CREATE TABLE group_sync_state ('
      'group_id TEXT NOT NULL, '
      'backend_key TEXT NOT NULL, '
      'base_rev INTEGER NOT NULL, '
      'remote_etag TEXT, '
      'last_synced_group_json TEXT, '
      'last_synced_at INTEGER NOT NULL, '
      'PRIMARY KEY (group_id, backend_key))',
];

/// v4 时代的旧数据：一条**已删除的残影**（books 行还在、local_path 已置
/// NULL，墓碑已记账）+ 一条正常书。
const _v4Inserts = [
  // 残影：旧版软删除留下的 books 行（local_path=NULL）+ 墓碑 + 进度 +
  // 按天阅读统计 + 仅本地标记（都是旧版「留元数据」留下的）。
  "INSERT INTO books (book_id, title, author, format, file_name, local_path, "
      "content_hash, size_bytes, cover_path, toc_fingerprint, added_at, "
      "last_read_at, total_seconds, group_id) VALUES "
      "('$_ghostBookId', '已删除的书', '作者', 'txt', 'ghost.txt', NULL, "
      "'sha256:ghost', 42, NULL, 'tfp:0000000000000000', 1700000000000, "
      "1700000100000, 123, NULL)",
  "INSERT INTO deleted_books (book_id, deleted_at, pushed, content_hash) "
      "VALUES ('$_ghostBookId', 1700000200000, 1, 'sha256:ghost')",
  "INSERT INTO progress (book_id, locator_json, percent, updated_at, dirty) "
      "VALUES ('$_ghostBookId', '{\"type\":\"raw\",\"ratio\":0.5}', 0.5, "
      "1700000100000, 0)",
  "INSERT INTO reading_days (book_id, day, seconds) "
      "VALUES ('$_ghostBookId', '2026-11-01', 300)",
  "INSERT INTO local_only_books (book_id, created_at) "
      "VALUES ('$_ghostBookId', 1700000000000)",
  // 正常书：未删除 → 迁移必须完好保留（含进度与按天统计）。
  "INSERT INTO books (book_id, title, author, format, file_name, local_path, "
      "content_hash, size_bytes, cover_path, toc_fingerprint, added_at, "
      "last_read_at, total_seconds, group_id) VALUES "
      "('$_aliveBookId', '正常书', '作者2', 'txt', 'alive.txt', '/tmp/alive.txt', "
      "'sha256:alive', 21, NULL, 'tfp:0000000000000000', 1700000000000, "
      "1700000300000, 77, NULL)",
  "INSERT INTO progress (book_id, locator_json, percent, updated_at, dirty) "
      "VALUES ('$_aliveBookId', '{\"type\":\"raw\",\"ratio\":0.25}', 0.25, "
      "1700000300000, 0)",
  "INSERT INTO reading_days (book_id, day, seconds) "
      "VALUES ('$_aliveBookId', '2026-11-02', 600)",
];

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) {
          rawDb.execute('PRAGMA foreign_keys=ON');
          for (final sql in _v4Ddl) {
            rawDb.execute(sql);
          }
          for (final sql in _v4Inserts) {
            rawDb.execute(sql);
          }
          // 关键：标记为 v4 库 → drift 打开时走 onUpgrade(4→5) 而非 onCreate。
          rawDb.execute('PRAGMA user_version = 4');
        },
      ),
    );
  });

  tearDown(() async => db.close());

  test('以 user_version=4 打开：走 onUpgrade(4→5)，残影行被清掉', () async {
    final versionRow = await db.customSelect('PRAGMA user_version').getSingle();
    expect(versionRow.data['user_version'], 5);

    // 残影书：books 行消失（不再出现在书库里）。
    expect(await db.booksDao.getById(_ghostBookId), isNull);
    expect(await db.booksDao.readAllBookIds(), isNot(contains(_ghostBookId)));
    // 子表行一并清掉（迁移在事务内跑，外键级联未生效 → 显式先删）。
    expect(await db.progressDao.getByBookId(_ghostBookId), isNull);
    expect(await db.readingDaysDao.daysByBook(_ghostBookId), isEmpty);
    expect(await db.localOnlyBooksDao.isLocalOnly(_ghostBookId), isFalse);
    // 墓碑账本保留（它才是"已删除"的留痕：驱动云端 tombstone 推送与 GC）。
    expect(await db.booksDao.hasTombstone(_ghostBookId), isTrue);
    final ledger = await db.select(db.deletedBooks).getSingle();
    expect(ledger.bookId, _ghostBookId);
    expect(ledger.pushed, isTrue);
  });

  test('未删除的书与旧数据完好（迁移只清残影）', () async {
    final book = await db.booksDao.getById(_aliveBookId);
    expect(book, isNotNull);
    expect(book!.title, '正常书');
    expect(book.localPath, '/tmp/alive.txt');
    expect(book.totalSeconds, 77);
    final progress = await db.progressDao.getByBookId(_aliveBookId);
    expect(progress, isNotNull);
    expect(progress!.percent, 0.25);
    expect(await db.readingDaysDao.totalSeconds(_aliveBookId), 600);
    // 无墓碑的书不受影响。
    expect(await db.booksDao.hasTombstone(_aliveBookId), isFalse);
  });

  test('schemaVersion == 5（docs/05 §6）', () => expect(db.schemaVersion, 5));
}
