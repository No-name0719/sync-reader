/// 阅读时长按天统计 DAO（FR-208，M4 补做）：每书 × 每自然日一行，秒数累加。
///
/// reading_days 仅本地表，不参与云端同步（docs/05 §5）。
library;

import 'package:drift/drift.dart';

import '../app_database.dart';
import '../tables.dart';

part 'reading_days_dao.g.dart';

/// 阅读日统计表访问对象。
@DriftAccessor(tables: [ReadingDays])
class ReadingDaysDao extends DatabaseAccessor<AppDatabase>
    with _$ReadingDaysDaoMixin {
  ReadingDaysDao(super.db);

  /// 累加某书某天的阅读秒数（upsert）。
  ///
  /// 单条 `INSERT … ON CONFLICT DO UPDATE SET seconds = seconds + ?` 完成，
  /// SQLite 侧原子累加（DoUpdate 里用列表达式，不先读后写）。
  /// [seconds] <= 0 直接忽略（无零/负时长）。
  Future<void> addSeconds(String bookId, String day, int seconds) {
    if (seconds <= 0) return Future.value();
    return into(readingDays).insert(
      ReadingDaysCompanion.insert(
        bookId: bookId,
        day: day,
        seconds: Value(seconds),
      ),
      onConflict: DoUpdate(
        (old) => ReadingDaysCompanion.custom(
          seconds: old.seconds + Constant(seconds),
        ),
      ),
    );
  }

  /// 某书按天统计，最近的日子在前（day DESC）。
  Future<List<ReadingDay>> daysByBook(String bookId) =>
      (select(readingDays)
            ..where((r) => r.bookId.equals(bookId))
            ..orderBy([(r) => OrderingTerm.desc(r.day)]))
          .get();

  /// 某书全期累计阅读秒数（无记录为 0）。
  Future<int> totalSeconds(String bookId) async {
    final query = selectOnly(readingDays)
      ..addColumns([readingDays.seconds.sum()])
      ..where(readingDays.bookId.equals(bookId));
    final row = await query.getSingle();
    return row.read(readingDays.seconds.sum()) ?? 0;
  }
}
