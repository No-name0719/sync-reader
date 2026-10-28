/// ReadingDaysDao 单元测试（FR-208）：按天累加 / 跨日隔离 / 排序 / 汇总 / 书删级联。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

void main() {
  late AppDatabase db;

  /// 造一本书（仅必填列）。
  Future<void> seedBook(String id) => db.booksDao.upsertCompanion(
    BooksCompanion.insert(
      bookId: id,
      title: '书$id',
      format: 'txt',
      fileName: '$id.txt',
      contentHash: 'sha256:$id',
      sizeBytes: 10,
      tocFingerprint: 'tfp:0000000000000000',
      addedAt: 1,
      localPath: Value('/tmp/$id'),
    ),
  );

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 立即触发 beforeOpen（外键 PRAGMA，级联删除依赖它）。
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async => db.close());

  group('ReadingDaysDao', () {
    test('addSeconds：同日两次累加 + seconds<=0 忽略', () async {
      await seedBook('01A');
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 30);
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 45);
      final rows = await db.readingDaysDao.daysByBook('01A');
      expect(rows, hasLength(1));
      expect(rows.single.day, '2026-10-27');
      expect(rows.single.seconds, 75);
      // 0 / 负数直接忽略：不建新行，也不改变现值。
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 0);
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', -5);
      await db.readingDaysDao.addSeconds('01A', '2026-10-28', 0);
      final after = await db.readingDaysDao.daysByBook('01A');
      expect(after, hasLength(1));
      expect(after.single.seconds, 75);
    });

    test('不同日期互不影响（每书 × 每自然日一行）', () async {
      await seedBook('01A');
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 30);
      await db.readingDaysDao.addSeconds('01A', '2026-10-28', 100);
      // 另一本书同一天，独立累加。
      await seedBook('01B');
      await db.readingDaysDao.addSeconds('01B', '2026-10-27', 7);
      final a = await db.readingDaysDao.daysByBook('01A');
      expect(a.map((r) => r.day), ['2026-10-28', '2026-10-27']);
      expect(a.map((r) => r.seconds), [100, 30]);
      final b = await db.readingDaysDao.daysByBook('01B');
      expect(b.single.seconds, 7);
    });

    test('daysByBook 按 day DESC 排序', () async {
      await seedBook('01A');
      await db.readingDaysDao.addSeconds('01A', '2026-10-01', 1);
      await db.readingDaysDao.addSeconds('01A', '2026-10-03', 1);
      await db.readingDaysDao.addSeconds('01A', '2026-10-02', 1);
      final days = (await db.readingDaysDao.daysByBook('01A'))
          .map((r) => r.day)
          .toList();
      expect(days, ['2026-10-03', '2026-10-02', '2026-10-01']);
    });

    test('totalSeconds 全期合计（无记录为 0）', () async {
      await seedBook('01A');
      expect(await db.readingDaysDao.totalSeconds('01A'), 0);
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 30);
      await db.readingDaysDao.addSeconds('01A', '2026-10-28', 12);
      await seedBook('01B');
      await db.readingDaysDao.addSeconds('01B', '2026-10-27', 999);
      expect(await db.readingDaysDao.totalSeconds('01A'), 42);
      expect(await db.readingDaysDao.totalSeconds('01B'), 999);
      expect(await db.readingDaysDao.totalSeconds('不存在'), 0);
    });

    test('书删除后按天记录级联清空（ON DELETE CASCADE）', () async {
      await seedBook('01A');
      await db.readingDaysDao.addSeconds('01A', '2026-10-27', 30);
      await db.readingDaysDao.addSeconds('01A', '2026-10-28', 12);
      await db.booksDao.softDelete('01A');
      expect(await db.readingDaysDao.daysByBook('01A'), isEmpty);
      expect(await db.readingDaysDao.totalSeconds('01A'), 0);
    });
  });
}
