/// ReaderSettingsRepository 测试：默认值 / JSON 往返 / 变更流 / 持久化 /
/// v1.1 旧值迁移（A11：旧主题名映射 + 新形态覆写落盘）。
library;

import 'dart:convert';

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
        theme: ReaderTheme.beige,
        fontFamily: '思源宋体',
        pageMode: ReaderPageMode.page,
        txtEncodingOverride: ReaderTextEncoding.gbk,
      ),
    );
    // 新仓库（新会话）从 DB 载入。
    final repo2 = ReaderSettingsRepository(db.readerSettingsDao);
    final loaded = await repo2.load();
    expect(loaded.fontSize, 22);
    expect(loaded.theme, ReaderTheme.beige);
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
      volumeKeyPageTurn: true,
    );
    final restored = ReaderSettings.fromJson(settings.toJson());
    expect(restored, settings);
    expect(
      restored.volumeKeyPageTurn,
      isTrue,
      reason: 'FR-209 音量键翻页 roundtrip',
    );
    // 未知枚举值/缺字段回落默认（docs/05 §6 演进规则）。
    final tolerant = ReaderSettings.fromJson({
      'theme': '未来新主题',
      'pageMode': 'page',
      'unknownFutureField': 1,
    });
    expect(tolerant.theme, ReaderTheme.paper, reason: '未知主题名回落默认纸白（A11）');
    expect(tolerant.pageMode, ReaderPageMode.page);
    expect(tolerant.fontSize, ReaderSettings.defaults.fontSize);
    expect(
      tolerant.volumeKeyPageTurn,
      isFalse,
      reason: '旧 JSON 无 volumeKeyPageTurn 键 → 默认 false',
    );
  });

  test('copyWith 覆盖与 clearFontFamily', () {
    const base = ReaderSettings(fontFamily: '宋体');
    expect(base.copyWith(fontSize: 20).fontSize, 20);
    expect(base.copyWith(fontSize: 20).fontFamily, '宋体');
    expect(base.copyWith(clearFontFamily: true).fontFamily, isNull);
  });

  group('v1.1 旧值迁移（A11：映射 + 覆写落盘）', () {
    Future<String> storedRaw() async {
      final raw = await db.readerSettingsDao.getValue(
        ReaderSettingsRepository.storageKey,
      );
      return raw ?? '';
    }

    test('v1.0 light → 迁移为 paper 并以新形态覆写', () async {
      await db.readerSettingsDao.setValue(
        ReaderSettingsRepository.storageKey,
        jsonEncode({
          'fontSize': 18.0,
          'lineHeight': 1.6,
          'pageMargin': 16.0,
          'theme': 'light',
          'fontFamily': null,
          'pageMode': 'scroll',
          'txtEncodingOverride': 'auto',
          'volumeKeyPageTurn': false,
        }),
      );
      final loaded = await repo.load();
      expect(loaded.theme, ReaderTheme.paper);
      // 覆写：库内 JSON 已为新形态（带 v:2 标记、主题名 paper）。
      final migrated = jsonDecode(await storedRaw()) as Map<String, Object?>;
      expect(migrated['v'], ReaderSettings.jsonSchemaVersion);
      expect(migrated['theme'], 'paper');
      expect(loaded.fontSize, 18.0, reason: '用户已持久化的设置不受影响');
    });

    test('v1.0 paper（米黄系纸张）→ 迁移为 beige 并覆写', () async {
      await db.readerSettingsDao.setValue(
        ReaderSettingsRepository.storageKey,
        jsonEncode({'theme': 'paper', 'pageMode': 'scroll'}),
      );
      final loaded = await repo.load();
      expect(loaded.theme, ReaderTheme.beige);
      final migrated = jsonDecode(await storedRaw()) as Map<String, Object?>;
      expect(migrated['theme'], 'beige');
      expect(migrated['v'], ReaderSettings.jsonSchemaVersion);
    });

    test('新形态 paper 恒为纸白，不误判为旧「纸张」', () async {
      // 先保存一次（写入新形态），再开新仓库读回。
      await repo.save(const ReaderSettings(theme: ReaderTheme.paper));
      final repo2 = ReaderSettingsRepository(db.readerSettingsDao);
      expect((await repo2.load()).theme, ReaderTheme.paper);
    });

    test('未知主题名 → 回落纸白并覆写归一', () async {
      await db.readerSettingsDao.setValue(
        ReaderSettingsRepository.storageKey,
        jsonEncode({'theme': '损坏的主题名'}),
      );
      final loaded = await repo.load();
      expect(loaded.theme, ReaderTheme.paper);
      final migrated = jsonDecode(await storedRaw()) as Map<String, Object?>;
      expect(migrated['theme'], 'paper');
      expect(migrated['v'], ReaderSettings.jsonSchemaVersion);
    });

    test('新形态数据重复 load 不重复覆写（幂等）', () async {
      await repo.save(const ReaderSettings(theme: ReaderTheme.green));
      final rawBefore = await storedRaw();
      final repo2 = ReaderSettingsRepository(db.readerSettingsDao);
      await repo2.load();
      expect(await storedRaw(), rawBefore, reason: '形态一致时不重写');
    });
  });
}
