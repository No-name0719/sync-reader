/// LocalOnlyBooksDao 单元测试（docs/10 §4.7c「仅本地 / 未上传」状态）：
/// 标记 / 解除 / 判定 / 集合读取 / watch 流 / 计数。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async => db.close());

  group('LocalOnlyBooksDao', () {
    test('markLocalOnly / isLocalOnly / clearLocalOnly', () async {
      expect(await db.localOnlyBooksDao.isLocalOnly('01A'), isFalse);
      await db.localOnlyBooksDao.markLocalOnly('01A');
      expect(await db.localOnlyBooksDao.isLocalOnly('01A'), isTrue);
      expect(await db.localOnlyBooksDao.isLocalOnly('01B'), isFalse);
      // 重复标记幂等（不抛错，行仍只有一条）。
      await db.localOnlyBooksDao.markLocalOnly('01A');
      expect(await db.localOnlyBooksDao.localOnlyBookIds(), {'01A'});
      // 解除标记。
      await db.localOnlyBooksDao.clearLocalOnly('01A');
      expect(await db.localOnlyBooksDao.isLocalOnly('01A'), isFalse);
      // 解除未标记的书也不报错。
      await db.localOnlyBooksDao.clearLocalOnly('01A');
    });

    test('标记时间写入 createdAt（epoch ms）', () async {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      await db.localOnlyBooksDao.markLocalOnly('01A', markedAt: at);
      final row = await db.select(db.localOnlyBooks).getSingle();
      expect(row.bookId, '01A');
      expect(row.createdAt, 1700000000000);
    });

    test('localOnlyBookIds / countLocalOnly', () async {
      expect(await db.localOnlyBooksDao.countLocalOnly(), 0);
      await db.localOnlyBooksDao.markLocalOnly('01A');
      await db.localOnlyBooksDao.markLocalOnly('01B');
      expect(await db.localOnlyBooksDao.countLocalOnly(), 2);
      expect(await db.localOnlyBooksDao.localOnlyBookIds(), {'01A', '01B'});
      await db.localOnlyBooksDao.clearLocalOnly('01A');
      expect(await db.localOnlyBooksDao.countLocalOnly(), 1);
      expect(await db.localOnlyBooksDao.localOnlyBookIds(), {'01B'});
    });

    test('watchLocalOnlyBookIds：标记/解除后流自动刷新', () async {
      final stream = db.localOnlyBooksDao.watchLocalOnlyBookIds();
      final first = await stream.first;
      expect(first, isEmpty);
      await db.localOnlyBooksDao.markLocalOnly('01A');
      expect(await stream.firstWhere((s) => s.contains('01A')), {'01A'});
      await db.localOnlyBooksDao.clearLocalOnly('01A');
      expect(await stream.firstWhere((s) => s.isEmpty), isEmpty);
    });
  });

  group('app_settings 表（docs/10 §3.1：accent 持久化等）', () {
    test('通用 key-value 表可写可读（读方容忍未知值）', () async {
      await db
          .into(db.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(key: 'accent', value: '"ochre"'),
          );
      final row = await db.select(db.appSettings).getSingle();
      expect(row.key, 'accent');
      expect(row.value, '"ochre"');
      // 覆盖写。
      await db
          .into(db.appSettings)
          .insertOnConflictUpdate(
            AppSettingsCompanion.insert(key: 'accent', value: '"celadon"'),
          );
      final rows = await db.select(db.appSettings).get();
      expect(rows, hasLength(1));
      expect(rows.single.value, '"celadon"');
    });
  });
}
