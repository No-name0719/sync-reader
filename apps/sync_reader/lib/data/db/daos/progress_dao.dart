/// 阅读进度 DAO（FR-201/207）：本地实时值 + 上传脏标记。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'progress_dao.g.dart';

/// 进度表访问对象。
@DriftAccessor(tables: [Progress])
class ProgressDao extends DatabaseAccessor<AppDatabase>
    with _$ProgressDaoMixin {
  ProgressDao(super.db);

  /// 取某书进度（未读过返回 null）。
  Future<BookProgress?> getByBookId(String bookId) => (select(
    progress,
  )..where((p) => p.bookId.equals(bookId))).getSingleOrNull();

  /// 写入/覆盖进度。
  ///
  /// [dirty] 默认 true（本地新产生的进度待上传）；同步层拉取远端进度时传 false。
  /// updatedAt 自动取当前时间。
  Future<void> upsert({
    required String bookId,
    required String locatorJson,
    required double percent,
    bool dirty = true,
  }) {
    assert(percent >= 0.0 && percent <= 1.0, 'percent 必须在 [0,1]（docs/05 §6）');
    return into(progress).insertOnConflictUpdate(
      ProgressCompanion.insert(
        bookId: bookId,
        locatorJson: locatorJson,
        percent: percent,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        dirty: Value(dirty),
      ),
    );
  }

  /// 监听所有待上传进度（M2 同步引擎消费）。
  Stream<List<BookProgress>> watchDirty() =>
      (select(progress)..where((p) => p.dirty.equals(true))).watch();

  /// 标记某书进度已同步（dirty = 0）。
  Future<void> markClean(String bookId) =>
      (update(progress)..where((p) => p.bookId.equals(bookId))).write(
        const ProgressCompanion(dirty: Value(false)),
      );
}
