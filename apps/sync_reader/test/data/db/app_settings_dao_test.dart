/// AppSettingsDao 单元测试（v1.1 重设计批 2）：getValue / setValue /
/// watchValue 基本行为（docs/10 §3.1 应用级设置持久化）。
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

  group('AppSettingsDao', () {
    test('不存在的键返回 null', () async {
      expect(await db.appSettingsDao.getValue('app.accent'), isNull);
    });

    test('setValue 后 getValue 读回', () async {
      await db.appSettingsDao.setValue('app.accent', 'teal');
      expect(await db.appSettingsDao.getValue('app.accent'), 'teal');
    });

    test('重复 setValue 覆盖旧值（不新增行）', () async {
      await db.appSettingsDao.setValue('app.accent', 'teal');
      await db.appSettingsDao.setValue('app.accent', 'ink');
      expect(await db.appSettingsDao.getValue('app.accent'), 'ink');
      final rows = await db.select(db.appSettings).get();
      expect(rows, hasLength(1));
    });

    test('不同键互不干扰', () async {
      await db.appSettingsDao.setValue('app.accent', 'teal');
      await db.appSettingsDao.setValue('app.theme_mode', 'dark');
      expect(await db.appSettingsDao.getValue('app.accent'), 'teal');
      expect(await db.appSettingsDao.getValue('app.theme_mode'), 'dark');
    });

    test('watchValue：初始 null，写入后推送新值，覆盖后推送覆盖值', () async {
      final events = <String?>[];
      final sub = db.appSettingsDao.watchValue('app.accent').listen(events.add);
      await Future<void>.delayed(Duration.zero);
      expect(events.first, isNull);

      await db.appSettingsDao.setValue('app.accent', 'teal');
      await Future<void>.delayed(Duration.zero);
      expect(events, contains('teal'));

      await db.appSettingsDao.setValue('app.accent', 'ink');
      await Future<void>.delayed(Duration.zero);
      expect(events.last, 'ink');

      await sub.cancel();
    });

    test('watchValue 对另一个键独立工作', () async {
      await db.appSettingsDao.setValue('app.theme_mode', 'dark');
      // 监听 app.accent 不受 theme_mode 写入影响。
      final value = await db.appSettingsDao.watchValue('app.accent').first;
      expect(value, isNull);
    });
  });
}
