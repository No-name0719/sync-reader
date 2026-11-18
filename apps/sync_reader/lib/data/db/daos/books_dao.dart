/// 书籍 DAO：书库查询 / 去重 / 删除（FR-101/102/105/106/408）。
///
/// 删除语义（docs/10 §4.7b，2026-11-18 变更）：本地删除 = **移出书库 +
/// 删正文文件 + 写墓碑**——`books` 行删除（进度级联清除），该书立刻从书库
/// 消失，与"其它设备删除后本机收到墓碑"的行为一致（同一语义两种表现是
/// 旧实现的缺陷）。墓碑账本仍在，驱动云端 tombstone 推送与 GC。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'books_dao.g.dart';

/// 书库排序方式（FR-105）。
enum BookSort {
  /// 最近阅读（从未阅读的排最后，按添加时间倒序兜底）。
  lastRead,

  /// 书名升序。
  title,

  /// 作者升序（同名按书名升序兜底）。
  author,

  /// 添加时间倒序。
  addedAt,
}

/// 书籍表访问对象。
@DriftAccessor(tables: [Books, Progress, DeletedBooks])
class BooksDao extends DatabaseAccessor<AppDatabase> with _$BooksDaoMixin {
  BooksDao(super.db);

  /// 监听书库列表：支持排序（FR-105）、书名/作者模糊搜索（FR-106）与
  /// 分组过滤（FR-107）。
  ///
  /// [query]：去首尾空白后为空则不过滤；命中 `title LIKE %q% OR author LIKE %q%`。
  /// [groupFilterId]：非空则只保留该分组的书；
  /// [ungroupedOnly]：true 则只保留未分组（group_id 为 NULL）的书。
  /// 两者同时传入以 [ungroupedOnly] 为准（UI 上为互斥的两种视图），
  /// 均不传 = 不做分组过滤（向后兼容原行为）。
  Stream<List<Book>> watchBooks({
    BookSort sort = BookSort.lastRead,
    String? query,
    String? groupFilterId,
    bool ungroupedOnly = false,
    bool undownloadedOnly = false,
  }) {
    final statement = select(books);
    final trimmed = query?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      final pattern = '%$trimmed%';
      statement.where((b) => b.title.like(pattern) | b.author.like(pattern));
    }
    // 分组过滤（FR-107 本地列；不影响搜索与排序语义）。
    if (ungroupedOnly) {
      statement.where((b) => b.groupId.isNull());
    } else if (groupFilterId != null) {
      statement.where((b) => b.groupId.equals(groupFilterId));
    }
    // 未下载过滤（FR-402 占位书：云端有元数据、本地无正文；与分组过滤
    // 的互斥由调用方保证，本层独立叠加）。
    // 注：本地已删除的书**不在此列表**——删除即移出书库（`books` 行删除，
    // docs/10 §4.7b），故「未下载」桶只剩真正的云端占位书。
    if (undownloadedOnly) {
      statement.where((b) => b.localPath.isNull());
    }
    switch (sort) {
      case BookSort.lastRead:
        // SQLite：DESC 排序下 NULL 天然排最后 → 未读过的书垫底。
        statement.orderBy([
          (b) => OrderingTerm.desc(b.lastReadAt),
          (b) => OrderingTerm.desc(b.addedAt),
        ]);
      case BookSort.title:
        statement.orderBy([(b) => OrderingTerm.asc(b.title)]);
      case BookSort.author:
        statement.orderBy([
          (b) => OrderingTerm.asc(b.author),
          (b) => OrderingTerm.asc(b.title),
        ]);
      case BookSort.addedAt:
        statement.orderBy([(b) => OrderingTerm.desc(b.addedAt)]);
    }
    return statement.watch();
  }

  /// 按 bookId 取书。
  Future<Book?> getById(String bookId) =>
      (select(books)..where((b) => b.bookId.equals(bookId))).getSingleOrNull();

  /// 全部 bookId 集合（一次性读取；游离文件扫描的差集用，FR-408）。
  Future<Set<String>> readAllBookIds() async {
    final rows = await select(books).get();
    return rows.map((b) => b.bookId).toSet();
  }

  /// 全部 bookId 集合流（drift watch；游离文件面板据此在挂回/入库后
  /// 自动重扫，FR-408）。
  Stream<Set<String>> watchAllBookIds() {
    final query = selectOnly(books)..addColumns([books.bookId]);
    return query.watch().map(
      (rows) => rows.map((row) => row.read(books.bookId)!).toSet(),
    );
  }

  /// 按正文哈希查询（导入去重，FR-101：同哈希提示"已存在"并复用条目）。
  Future<Book?> getByContentHash(String contentHash) => (select(
    books,
  )..where((b) => b.contentHash.equals(contentHash))).getSingleOrNull();

  /// 插入或整行覆盖（以 bookId 为冲突键）。
  Future<void> upsert(Book book) =>
      into(books).insertOnConflictUpdate(book.toCompanion(true));

  /// 插入或部分覆盖（支持只写部分列的调用方）。
  Future<void> upsertCompanion(BooksCompanion entry) =>
      into(books).insertOnConflictUpdate(entry);

  /// 需要补封面的书：正文已落盘但 coverPath 为空（云端下载的书/存量回填）。
  Future<List<Book>> missingCovers() => (select(
    books,
  )..where((b) => b.localPath.isNotNull() & b.coverPath.isNull())).get();

  /// 登记封面路径（封面落盘后调用；书库列表经 drift watch 自动刷新）。
  Future<void> updateCoverPath(String bookId, String coverPath) {
    return (update(books)..where((b) => b.bookId.equals(bookId))).write(
      BooksCompanion(coverPath: Value(coverPath)),
    );
  }

  /// 设置书所属分组（FR-107 本地列）；[groupId] 传 null = 移出分组（未分组）。
  Future<void> setGroup(String bookId, String? groupId) {
    return (update(books)..where((b) => b.bookId.equals(bookId))).write(
      BooksCompanion(groupId: Value(groupId)),
    );
  }

  /// 更新重解析元数据列（FR-410 文件替换：新文件重解析后回写）。
  ///
  /// 仅写入非 null 实参对应的列——null 表示"保留旧值"（解析失败降级时
  /// title/author/tocFingerprint 不动；无新封面字节时旧封面保留）。
  /// 文件指征列（fileName/contentHash/sizeBytes/format/localPath）由
  /// `DriftLocalLibrary.updateBookFileInfo` 负责，两路各管各的列。
  Future<void> updateParsedMeta(
    String bookId, {
    String? title,
    String? author,
    String? tocFingerprint,
    String? coverPath,
  }) {
    return (update(books)..where((b) => b.bookId.equals(bookId))).write(
      BooksCompanion(
        title: title == null ? const Value.absent() : Value(title),
        author: author == null ? const Value.absent() : Value(author),
        tocFingerprint: tocFingerprint == null
            ? const Value.absent()
            : Value(tocFingerprint),
        coverPath: coverPath == null ? const Value.absent() : Value(coverPath),
      ),
    );
  }

  /// 更新阅读统计（FR-207：lastReadAt / totalSeconds）。
  ///
  /// - [lastReadAt]：传则覆盖；
  /// - [totalSeconds]：传则覆盖为绝对值；
  /// - [addTotalSeconds]：传则在现值上累加（阅读会话用）。
  Future<void> updateProgressInfo(
    String bookId, {
    DateTime? lastReadAt,
    int? totalSeconds,
    int? addTotalSeconds,
  }) {
    if (addTotalSeconds != null) {
      // 累加语义：读现值再写回（单进程内顺序调用，无需事务级并发控制）。
      return transaction(() async {
        final book = await getById(bookId);
        if (book == null) return;
        await (update(books)..where((b) => b.bookId.equals(bookId))).write(
          BooksCompanion(
            totalSeconds: Value(book.totalSeconds + addTotalSeconds),
            lastReadAt: lastReadAt == null
                ? const Value.absent()
                : Value(lastReadAt.millisecondsSinceEpoch),
          ),
        );
      });
    }
    final companion = BooksCompanion(
      lastReadAt: lastReadAt == null
          ? const Value.absent()
          : Value(lastReadAt.millisecondsSinceEpoch),
      totalSeconds: totalSeconds == null
          ? const Value.absent()
          : Value(totalSeconds),
    );
    return (update(
      books,
    )..where((b) => b.bookId.equals(bookId))).write(companion);
  }

  /// 删除本书（FR-408 / docs/10 §4.7b 删除语义）：
  /// **移出书库 + 删正文文件 + 写墓碑**。
  ///
  /// - `books` 行**删除** → 该书立刻从书库消失（进度行随之级联清除：
  ///   `progress` / `reading_days` 的 `ON DELETE CASCADE`）；
  /// - 写 `deleted_books` 墓碑账本（供同步引擎推云端 tombstone 与 90 天
  ///   GC）；**云端正文文件不删**（docs/04 §7.1 规则 4：云端正文永不删除，
  ///   残留由"云端孤儿清理"工具回收）；
  /// - 清除「仅本地」标记（书已不存在，标记留着会让"未上传的书"计数虚高）；
  /// - 正文/封面文件由调用方删除：DAO 不持有 file store，通过 [removeFiles]
  ///   回调串起来（传 `store.deleteBookFiles` 即可）。回调在事务提交后执行，
  ///   失败不回滚 DB 变更（文件删除是幂等的，可重试）。
  ///
  /// 幂等：重复删除同一本书不报错（墓碑按首次删除时间保留）。
  Future<void> deleteBook(
    String bookId, {
    DateTime? deletedAt,
    Future<void> Function(String bookId)? removeFiles,
  }) async {
    final now = (deletedAt ?? DateTime.now()).millisecondsSinceEpoch;
    final removed = await transaction(() async {
      final book = await getById(bookId);
      if (book == null) return false;
      // 墓碑账本：已存在（重复删除）时保留首次删除时间，不覆盖。
      final existing = await (select(
        deletedBooks,
      )..where((d) => d.bookId.equals(bookId))).getSingleOrNull();
      if (existing == null) {
        await into(deletedBooks).insert(
          DeletedBooksCompanion.insert(
            bookId: bookId,
            deletedAt: now,
            contentHash: book.contentHash,
          ),
        );
      }
      // 移出书库：删 books 行（progress / reading_days 级联清除）。
      await (delete(books)..where((b) => b.bookId.equals(bookId))).go();
      // 「仅本地」标记随书一起失效（否则"未上传的书"计数虚高）。
      final localOnly = attachedDatabase.localOnlyBooks;
      await (delete(localOnly)..where((l) => l.bookId.equals(bookId))).go();
      return true;
    });
    if (removed && removeFiles != null) {
      // 正文/封面真正删盘（释放磁盘空间，不可恢复）。
      await removeFiles(bookId);
    }
  }

  /// 该书是否有本地墓碑（本地删除或已确认的远端 tombstone）。
  ///
  /// 「已删除」判定入口（docs/10 §4.7b）：删除即移出书库，本表有墓碑即表示
  /// 该书已被删除（或已确认的远端 tombstone）。未删除的书返回 false。
  Future<bool> hasTombstone(String bookId) async {
    final query = selectOnly(deletedBooks)
      ..addColumns([deletedBooks.bookId])
      ..where(deletedBooks.bookId.equals(bookId));
    return (await query.getSingleOrNull()) != null;
  }

  /// 墓碑 bookId 集合流（v1.1 书库重设计 A18 的只读数据源之一；
  /// 语义与 [hasTombstone] 一致，仅提供 watch 形态，不改任何写语义）。
  Stream<Set<String>> watchTombstonedBookIds() {
    final query = selectOnly(deletedBooks)..addColumns([deletedBooks.bookId]);
    return query.watch().map(
      (rows) => rows.map((row) => row.read(deletedBooks.bookId)!).toSet(),
    );
  }

  /// `sync_state` 中有行（= 云端有 baseRev）的 bookId 集合流。
  ///
  /// v1.1 书库重设计（A18）只读数据源：「云端有」的近似判定 = 本表有该书
  /// 的行且不在本轮 cloudMissingMarks 里（docs/10 §4.2，Q20 四态分区）。
  /// 通过 `attachedDatabase` 引用 SyncState 表（本 DAO 未声明该表，
  /// 避免为此重新生成代码）；只读查询，不改任何写语义。
  Stream<Set<String>> watchSyncStateBookIds() {
    final table = attachedDatabase.syncState;
    final query = selectOnly(table)..addColumns([table.bookId]);
    return query.watch().map(
      (rows) => rows.map((row) => row.read(table.bookId)!).toSet(),
    );
  }
}
