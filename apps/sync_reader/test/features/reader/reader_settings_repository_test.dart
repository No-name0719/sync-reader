/// ReaderSettingsRepository 测试：默认值 / JSON 往返 / 变更流 / 持久化。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/reader_settings_repository.dart';

void main() {
  late AppDatabase db;
  late ReaderSettingsRepository repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ReaderSettingsRepository(db.readerSettingsDao);
  });

  tearDown(() async => db.close());

  test('未载入时为出厂默认，load 后读回已保存值', () async {
    expect(repo.current, ReaderSettings.defaults);
    // 先保存一份自定义值（模拟上次会话）。
    await repo.save(
      const ReaderSettings(
        fontSize: 22,
        lineHeight: 1.8,
        pageMargin: 24,
        theme: ReaderTheme.paper,
        fontFamily: '思源宋体',
        pageMode: ReaderPageMode.page,
        txtEncodingOverride: ReaderTextEncoding.gbk,
      ),
    );
    // 新仓库（新会话）从 DB 载入。
    final repo2 = ReaderSettingsRepository(db.readerSettingsDao);
    final loaded = await repo2.load();
    expect(loaded.fontSize, 22);
    expect(loaded.theme, ReaderTheme.paper);
    expect(loaded.pageMode, ReaderPageMode.page);
    expect(loaded.txtEncodingOverride, ReaderTextEncoding.gbk);
    expect(repo2.current, loaded);
  });

  test('save 更新缓存并广播变更', () async {
    await repo.load();
    final emissions = <ReaderSettings>[];
    final sub = repo.changes.listen(emissions.add);
    await repo.save(
      const ReaderSettings(fontSize: 30, theme: ReaderTheme.dark),
    );
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(emissions, hasLength(1));
    expect(emissions.single.fontSize, 30);
    expect(repo.current.fontSize, 30);
  });

  test('JSON 往返与未知字段容忍', () {
    const settings = ReaderSettings(
      fontSize: 24,
      lineHeight: 1.5,
      pageMargin: 20,
      theme: ReaderTheme.dark,
      fontFamily: '黑体',
      pageMode: ReaderPageMode.page,
      txtEncodingOverride: ReaderTextEncoding.utf8,
    );
    final restored = ReaderSettings.fromJson(settings.toJson());
    expect(restored, settings);
    // 未知枚举值/缺字段回落默认（docs/05 §6 演进规则）。
    final tolerant = ReaderSettings.fromJson({
      'theme': '未来新主题',
      'pageMode': 'page',
      'unknownFutureField': 1,
    });
    expect(tolerant.theme, ReaderTheme.light);
    expect(tolerant.pageMode, ReaderPageMode.page);
    expect(tolerant.fontSize, ReaderSettings.defaults.fontSize);
  });

  test('copyWith 覆盖与 clearFontFamily', () {
    const base = ReaderSettings(fontFamily: '宋体');
    expect(base.copyWith(fontSize: 20).fontSize, 20);
    expect(base.copyWith(fontSize: 20).fontFamily, '宋体');
    expect(base.copyWith(clearFontFamily: true).fontFamily, isNull);
  });
}
