/// 仅本地书籍标记 DAO（docs/10 §4.7c「仅本地 / 未上传」状态）。
///
/// 命中本表的书**永不参与 diff**：既不推 meta 也不传正文（同步引擎完全
/// 看不见它）。两种来源在 UI 上是同一个状态：
/// - 导入时取消勾选「同时上传到云端」；
/// - 「从云端移除」后各端因仍有 baseRev 落 diff 第 7b 行（云端缺失）。
///
/// 纯本地表，不参与同步、不入云端 meta（docs/05 §5）。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'local_only_books_dao.g.dart';

/// 仅本地标记表访问对象。
@DriftAccessor(tables: [LocalOnlyBooks])
class LocalOnlyBooksDao extends DatabaseAccessor<AppDatabase>
    with _$LocalOnlyBooksDaoMixin {
  LocalOnlyBooksDao(super.db);

  /// 标记为「仅本地」（不上传云端）。幂等：重复标记只更新标记时间。
  Future<void> markLocalOnly(String bookId, {DateTime? markedAt}) {
    return into(localOnlyBooks).insertOnConflictUpdate(
      LocalOnlyBooksCompanion.insert(
        bookId: bookId,
        createdAt: Value((markedAt ?? DateTime.now()).millisecondsSinceEpoch),
      ),
    );
  }

  /// 解除「仅本地」标记（恢复为正常同步的书）。幂等：未标记也不报错。
  Future<void> clearLocalOnly(String bookId) {
    return (delete(
      localOnlyBooks,
    )..where((row) => row.bookId.equals(bookId))).go();
  }

  /// 该书是否被标记为「仅本地」。
  Future<bool> isLocalOnly(String bookId) async {
    final query = selectOnly(localOnlyBooks)
      ..addColumns([localOnlyBooks.bookId])
      ..where(localOnlyBooks.bookId.equals(bookId));
    return (await query.getSingleOrNull()) != null;
  }

  /// 全部「仅本地」bookId 集合（一次性读取）。
  Future<Set<String>> localOnlyBookIds() async {
    final rows = await select(localOnlyBooks).get();
    return rows.map((row) => row.bookId).toSet();
  }

  /// 「仅本地」bookId 集合流（书库页角标/同步页「未上传的书」卡片 watch）。
  Stream<Set<String>> watchLocalOnlyBookIds() {
    final query = selectOnly(localOnlyBooks)
      ..addColumns([localOnlyBooks.bookId]);
    return query.watch().map(
      (rows) => rows.map((row) => row.read(localOnlyBooks.bookId)!).toSet(),
    );
  }

  /// 「仅本地」书的数量（书库页状态筛选计数用）。
  Future<int> countLocalOnly() async {
    final count = localOnlyBooks.bookId.count();
    final query = selectOnly(localOnlyBooks)..addColumns([count]);
    return (await query.getSingle()).read(count) ?? 0;
  }
}
