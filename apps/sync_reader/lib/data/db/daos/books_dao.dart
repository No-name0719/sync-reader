/// 书籍 DAO：书库查询 / 去重 / 软删除（FR-101/102/105/106）。
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

  /// 软删除：写 tombstone 账本（deleted_books）+ 从 books 移除（进度级联清除）。
  ///
  /// 正文文件不在此删除——调用方决定交给 [BookFileStore.deleteBookFiles]
  /// 或移入游离目录（docs/04 §7：永不自动删正文的语义由上层把握）。
  Future<void> softDelete(String bookId, {DateTime? deletedAt}) {
    final now = (deletedAt ?? DateTime.now()).millisecondsSinceEpoch;
    return transaction(() async {
      final book = await getById(bookId);
      if (book == null) return;
      await into(deletedBooks).insertOnConflictUpdate(
        DeletedBooksCompanion.insert(
          bookId: bookId,
          deletedAt: now,
          contentHash: book.contentHash,
        ),
      );
      await (delete(books)..where((b) => b.bookId.equals(bookId))).go();
    });
  }
}
