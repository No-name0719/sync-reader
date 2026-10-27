/// 待同步队列 DAO（docs/05 §5 sync_queue，M2 同步引擎使用）。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'sync_queue_dao.g.dart';

/// 同步队列表访问对象。
@DriftAccessor(tables: [SyncQueue])
class SyncQueueDao extends DatabaseAccessor<AppDatabase>
    with _$SyncQueueDaoMixin {
  SyncQueueDao(super.db);

  /// 入队（FIFO；重复入队由调用方决定，M1 不做约束）。
  Future<void> enqueue({required String bookId, required String op}) =>
      into(syncQueue).insert(
        SyncQueueCompanion.insert(
          bookId: bookId,
          op: op,
          enqueuedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  /// 按入队序列出队列。
  Future<List<SyncQueueEntry>> list({int? limit}) {
    final statement = select(syncQueue)
      ..orderBy([(q) => OrderingTerm.asc(q.id)]);
    if (limit != null) statement.limit(limit);
    return statement.get();
  }

  /// 出队（按 id 移除）。
  Future<void> remove(int id) =>
      (delete(syncQueue)..where((q) => q.id.equals(id))).go();
}
