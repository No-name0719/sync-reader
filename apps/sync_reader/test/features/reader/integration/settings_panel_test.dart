/// 阅读设置面板 widget 测试（FR-206）：调整字号/主题/翻页模式 →
/// repository.save 被调用并持久化到内存库 reader_settings 表。
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/reader_settings_repository.dart';
import 'package:sync_reader/features/reader/settings/settings_panel.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    // 预载（阅读页打开面板前已完成 load；此处对齐同一前置）。
    await container.read(readerSettingsRepositoryProvider).load();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ReaderSettingsPanel())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 面板内部滚动视图（面板自带 SingleChildScrollView，测试滚动定位用）。
  Finder panelScroller() => find.descendant(
    of: find.byType(ReaderSettingsPanel),
    matching: find.byType(SingleChildScrollView),
  );

  testWidgets('拖动字号滑杆 → repository.save 持久化（内存实现）', (tester) async {
    await pumpPanel(tester);

    await tester.drag(
      find.byKey(const ValueKey('settings-font-size')),
      const Offset(160, 0),
    );
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.fontSize, greaterThan(18), reason: '默认 18，右拖应增大');

    final raw = await db.readerSettingsDao.getValue(
      ReaderSettingsRepository.storageKey,
    );
    expect(raw, isNotNull);
    final persisted = ReaderSettings.fromJson(
      jsonDecode(raw!) as Map<String, Object?>,
    );
    expect(persisted.fontSize, repo.current.fontSize);
  });

  testWidgets('主题三选（色块预览）→ 纸张生效并持久化', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byKey(const ValueKey('settings-theme-paper')));
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.theme, ReaderTheme.paper);
    final raw = await db.readerSettingsDao.getValue(
      ReaderSettingsRepository.storageKey,
    );
    expect(raw, contains('"theme":"paper"'));
  });

  testWidgets('翻页模式切分页 + txt 编码切 GBK', (tester) async {
    await pumpPanel(tester);

    await tester.dragUntilVisible(
      find.text('翻页模式'),
      panelScroller(),
      const Offset(0, -60),
    );
    await tester.tap(find.text('分页').last);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('txt 编码'),
      panelScroller(),
      const Offset(0, -60),
    );
    await tester.tap(find.text('GBK').last);
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.pageMode, ReaderPageMode.page);
    expect(repo.current.txtEncodingOverride, ReaderTextEncoding.gbk);
  });
}
