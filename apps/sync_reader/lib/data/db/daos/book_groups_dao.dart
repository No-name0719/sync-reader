/// 书籍分组 DAO（FR-107，本地分类）：book_groups 仅本地表，
/// v1 不参与同步、不入云端 meta（docs/05 §5）。
library;

import 'package:drift/drift.dart';

import '../../../core/ulid.dart';
import '../app_database.dart';
import '../tables.dart';

part 'book_groups_dao.g.dart';

/// 分组表访问对象。
@DriftAccessor(tables: [BookGroups, Books])
class BookGroupsDao extends DatabaseAccessor<AppDatabase>
    with _$BookGroupsDaoMixin {
  BookGroupsDao(super.db);

  /// 全部分组（排序权重升序，同权重按创建顺序）。
  Future<List<BookGroup>> allGroups() =>
      (select(bookGroups)
            ..orderBy([
              (g) => OrderingTerm.asc(g.sortOrder),
              (g) => OrderingTerm.asc(g.createdAt),
            ]))
          .get();

  /// 新建分组：ULID 主键，sortOrder 排到当前末尾（空表为 0），createdAt 取现在。
  ///
  /// trim 后空白名抛 [ArgumentError]。重名不在 SQL 层约束（SQLite 的
  /// 大小写/空白语义复杂），由调用方先用 [nameExists] 拒绝（FR-107 UI 侧）。
  Future<BookGroup> createGroup(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '分组名不能为空白');
    }
    return transaction(() async {
      final query = selectOnly(bookGroups)
        ..addColumns([bookGroups.sortOrder.max()]);
      final maxOrder =
          (await query.getSingle()).read(bookGroups.sortOrder.max()) ?? -1;
      final group = BookGroup(
        groupId: generateUlid(),
        name: trimmed,
        sortOrder: maxOrder + 1,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      await into(bookGroups).insert(group);
      return group;
    });
  }

  /// 重命名分组（trim 后空白名抛 [ArgumentError]）。
  Future<void> renameGroup(String groupId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '分组名不能为空白');
    }
    return (update(bookGroups)..where((g) => g.groupId.equals(groupId))).write(
      BookGroupsCompanion(name: Value(trimmed)),
    );
  }

  /// 删除分组；所属书籍的 group_id 由外键 `ON DELETE SET NULL` 置回未分组
  ///（依赖连接开启 PRAGMA foreign_keys，见 [AppDatabase.migration] beforeOpen）。
  Future<void> deleteGroup(String groupId) =>
      (delete(bookGroups)..where((g) => g.groupId.equals(groupId))).go();

  /// 分组名是否已存在（trim 后精确匹配，供 UI 拒绝重名）。
  Future<bool> nameExists(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final query = selectOnly(bookGroups)
      ..addColumns([bookGroups.groupId])
      ..where(bookGroups.name.equals(trimmed));
    return (await query.getSingleOrNull()) != null;
  }
}
