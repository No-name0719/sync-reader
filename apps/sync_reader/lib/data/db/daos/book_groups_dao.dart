/// 书籍分组 DAO（FR-107，v1.4 起参与云端同步，docs/05 §2.1）。
///
/// 分组本体是本地行；云端形态为 `groups/{groupId}.json`，同步由
/// `sync_core` 的分组阶段负责（rev/CAS/LWW 与书籍一致）。
///
/// **软删语义**（docs/04 §7.1 同款）：删除分组 = 置 `deleted=1` +
/// 组内书籍 `group_id` 置 NULL（回到未分组）；**行保留**，以便离线时把
/// 分组墓碑补推上云（墓碑上云成功后由同步层硬删该行）。
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

  /// 全部分组（排序权重升序，同权重按创建顺序）；**不含已软删分组**。
  Future<List<BookGroup>> allGroups() => _liveQuery().get();

  /// 全部分组（含已软删、待推墓碑的分组）——同步层用。
  Future<List<BookGroup>> allGroupsIncludingDeleted() =>
      (select(bookGroups)..orderBy([
            (g) => OrderingTerm.asc(g.sortOrder),
            (g) => OrderingTerm.asc(g.createdAt),
          ]))
          .get();

  /// 按 id 取分组（含已软删的）；不存在返回 null。
  Future<BookGroup?> groupById(String groupId) => (select(
    bookGroups,
  )..where((g) => g.groupId.equals(groupId))).getSingleOrNull();

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
        deleted: false,
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

  /// 删除分组（软删）：置 `deleted=1` + 组内书籍 `group_id` 置 NULL
  /// （组内书籍回到未分组，不丢书）。
  ///
  /// 行保留 → 离线时也能在下次同步把分组墓碑补推上云（docs/04 §7.1）。
  Future<void> deleteGroup(String groupId) => transaction(() async {
    await (update(bookGroups)..where((g) => g.groupId.equals(groupId))).write(
      BookGroupsCompanion(
        deleted: const Value(true),
        deletedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    await (update(books)..where((b) => b.groupId.equals(groupId))).write(
      const BooksCompanion(groupId: Value(null)),
    );
  });

  /// 同名分组合并（名称级去重，docs/05 §2.1）：把 [fromGroupId] 的书籍
  /// 外键迁到 [toGroupId]，删除 [fromGroupId] 行。
  ///
  /// [toGroupId] 行不存在时以 [toName]/[toSortOrder] 建立（远端拉取阶段
  /// 会用权威值覆盖）。
  Future<void> mergeGroup({
    required String fromGroupId,
    required String toGroupId,
    required String toName,
    required int toSortOrder,
  }) => transaction(() async {
    final target = await groupById(toGroupId);
    if (target == null) {
      await into(bookGroups).insert(
        BookGroup(
          groupId: toGroupId,
          name: toName,
          sortOrder: toSortOrder,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          deleted: false,
        ),
      );
    }
    await (update(books)..where((b) => b.groupId.equals(fromGroupId))).write(
      BooksCompanion(groupId: Value(toGroupId)),
    );
    await (delete(
      bookGroups,
    )..where((g) => g.groupId.equals(fromGroupId))).go();
  });

  /// 分组名是否已存在（trim 后精确匹配，供 UI 拒绝重名；不含已软删分组）。
  Future<bool> nameExists(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final query = selectOnly(bookGroups)
      ..addColumns([bookGroups.groupId])
      ..where(
        bookGroups.name.equals(trimmed) & bookGroups.deleted.equals(false),
      );
    return (await query.getSingleOrNull()) != null;
  }

  /// 活分组查询（不含已软删分组）。
  SimpleSelectStatement<$BookGroupsTable, BookGroup> _liveQuery() =>
      (select(bookGroups)
        ..where((g) => g.deleted.equals(false))
        ..orderBy([
          (g) => OrderingTerm.asc(g.sortOrder),
          (g) => OrderingTerm.asc(g.createdAt),
        ]));
}
