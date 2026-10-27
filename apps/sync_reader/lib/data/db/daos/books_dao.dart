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

  /// 监听书库列表：支持排序（FR-105）与书名/作者模糊搜索（FR-106）。
  ///
  /// [query]：去首尾空白后为空则不过滤；命中 `title LIKE %q% OR author LIKE %q%`。
  Stream<List<Book>> watchBooks({
    BookSort sort = BookSort.lastRead,
    String? query,
  }) {
    final statement = select(books);
    final trimmed = query?.trim() ?? '';
    if (trimmed.isNotEmpty) {
      final pattern = '%$trimmed%';
      statement.where((b) => b.title.like(pattern) | b.author.like(pattern));
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
