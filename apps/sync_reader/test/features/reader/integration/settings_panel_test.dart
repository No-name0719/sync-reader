/// 阅读设置面板（v1.2 B4 齿轮入口，A9 重做）widget 测试：调整字号/背景/
/// 翻页模式/字体/段距/缩进/夜间亮度/翻页动画 → repository.save 被调用并
/// 持久化到内存库 reader_settings 表；实时预览框随字号即时变化；对比度
/// 读数按主题色实算；夜间亮度仅在夜间系背景显示；翻页动画仅在分页模式显示。
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
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

  /// 预览框内示例文字（实时预览的排版探针）。
  Finder previewText() => find.descendant(
    of: find.byKey(const ValueKey('aa-preview')),
    matching: find.byType(Text),
  );

  testWidgets('拖动字号滑杆 → repository.save 持久化（内存实现）', (tester) async {
    await pumpPanel(tester);

    await tester.drag(
      find.byKey(const ValueKey('settings-font-size')),
      const Offset(160, 0),
    );
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.fontSize, greaterThan(18), reason: '默认 19，右拖应增大');

    final raw = await db.readerSettingsDao.getValue(
      ReaderSettingsRepository.storageKey,
    );
    expect(raw, isNotNull);
    final persisted = ReaderSettings.fromJson(
      jsonDecode(raw!) as Map<String, Object?>,
    );
    expect(persisted.fontSize, repo.current.fontSize);
  });

  testWidgets('实时预览框（A9）：字号随滑杆即时变化且带 2em 缩进', (tester) async {
    await pumpPanel(tester);

    final before = tester.widget<Text>(previewText());
    expect(before.data, startsWith(kReaderParagraphIndent), reason: '首行缩进 2em');
    expect(before.style!.fontSize, 19, reason: '出厂字号 19（A14）');

    await tester.drag(
      find.byKey(const ValueKey('settings-font-size')),
      const Offset(80, 0),
    );
    await tester.pump();

    final after = tester.widget<Text>(previewText());
    final repo = container.read(readerSettingsRepositoryProvider);
    expect(after.style!.fontSize, repo.current.fontSize, reason: '预览随选项即时变化');
    expect(after.style!.height, repo.current.lineHeight);
  });

  testWidgets('背景七选（B2）：米黄生效并持久化，七块齐备', (tester) async {
    await pumpPanel(tester);

    // 四套主题色块（纸白/米黄/护眼/夜间）。
    for (final theme in ReaderTheme.values) {
      expect(
        find.byKey(ValueKey('settings-theme-${theme.name}')),
        findsOneWidget,
      );
    }

    await tester.dragUntilVisible(
      find.byKey(const ValueKey('settings-theme-beige')),
      panelScroller(),
      const Offset(0, -60),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-theme-beige')));
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.theme, ReaderTheme.beige);
    final raw = await db.readerSettingsDao.getValue(
      ReaderSettingsRepository.storageKey,
    );
    expect(raw, contains('"theme":"beige"'));
    // 预览框背景跟随所选主题。
    final previewContainer = tester.widget<Container>(
      find.byKey(const ValueKey('aa-preview')),
    );
    expect(
      (previewContainer.decoration! as BoxDecoration).color,
      ReaderTheme.beige.palette.bg,
    );
  });

  testWidgets('字体三选：各选项以自身字体渲染，选择写入 AppFonts 常量', (tester) async {
    await pumpPanel(tester);

    // 三个选项的预览字样分别用衬线/黑体/楷体渲染（A9）。
    for (final family in [AppFonts.serif, AppFonts.sans, AppFonts.kai]) {
      final option = find.byKey(ValueKey('settings-font-$family'));
      expect(option, findsOneWidget);
      final sampleText = tester.widget<Text>(
        find.descendant(of: option, matching: find.byType(Text)).first,
      );
      expect(sampleText.style!.fontFamily, family, reason: '$family 预览字样');
    }

    // B4 新增段距/缩进分组后面板更长：先滚动到字体区再点选。
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('settings-font-${AppFonts.sans}')),
      panelScroller(),
      const Offset(0, -60),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('settings-font-${AppFonts.sans}')),
    );
    await tester.pump();
    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.fontFamily, AppFonts.sans);
    expect(repo.current.resolvedFontFamily, AppFonts.sans);
  });

  testWidgets('翻页模式（Q9 默认分页）+ txt 编码切 GBK', (tester) async {
    await pumpPanel(tester);
    expect(
      container.read(readerSettingsRepositoryProvider).current.pageMode,
      ReaderPageMode.page,
      reason: 'Q9：出厂默认分页',
    );

    await tester.dragUntilVisible(
      find.text('翻页模式'),
      panelScroller(),
      const Offset(0, -60),
    );
    // 切滚动（默认分页下切到另一档，验证控件生效）。
    await tester.tap(find.text('滚动').last);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('txt 编码'),
      panelScroller(),
      const Offset(0, -60),
    );
    await tester.tap(find.text('GBK').last);
    await tester.pump();

    final repo = container.read(readerSettingsRepositoryProvider);
    expect(repo.current.pageMode, ReaderPageMode.scroll);
    expect(repo.current.txtEncodingOverride, ReaderTextEncoding.gbk);
  });

  group('v1.2 B4/B5 新增设置项', () {
    testWidgets('对比度读数：按当前主题色实算（白色主题正文 ≥7:1 AAA）', (tester) async {
      await pumpPanel(tester);
      final note = find.byKey(const ValueKey('aa-contrast-note'));
      expect(note, findsOneWidget);
      final palette = ReaderTheme.paper.palette;
      final expected =
          '正文对比度 ${palette.fgContrast.toStringAsFixed(1)}:1 · '
          '${wcagContrastLevel(palette.fgContrast)}'
          '　|　次级文字 ${palette.mutedContrast.toStringAsFixed(1)}:1';
      expect(tester.widget<Text>(note).data, expected);
    });

    testWidgets('段距三选（B4）：空一行写入并持久化', (tester) async {
      await pumpPanel(tester);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('settings-paragraph-gap')),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('空一行').last);
      await tester.pump();

      final repo = container.read(readerSettingsRepositoryProvider);
      expect(repo.current.paragraphGap, ReaderParagraphGap.oneLine);
      final raw = await db.readerSettingsDao.getValue(
        ReaderSettingsRepository.storageKey,
      );
      expect(raw, contains('"paragraphGap":"oneLine"'));
    });

    testWidgets('首行缩进开关（B4）：关闭后预览不再带 2em 缩进且持久化', (tester) async {
      await pumpPanel(tester);
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('settings-first-line-indent')),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('不缩进').last);
      await tester.pump();

      final repo = container.read(readerSettingsRepositoryProvider);
      expect(repo.current.firstLineIndent, isFalse);
      expect(
        tester.widget<Text>(previewText()).data,
        isNot(startsWith(kReaderParagraphIndent)),
        reason: '预览跟随缩进开关',
      );
    });

    testWidgets('夜间亮度（B3）：浅色背景不显示滑杆，夜间背景显示且可调',
        (tester) async {
      await pumpPanel(tester);
      // 出厂白色（浅色系）：无夜间亮度滑杆。
      expect(find.byKey(const ValueKey('settings-night-brightness')), findsNothing);

      // 切到夜间系背景（深灰）后滑杆出现。
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('settings-theme-dark')),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-theme-dark')));
      await tester.pump();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('settings-night-brightness')),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byKey(const ValueKey('settings-night-brightness')),
        const Offset(-120, 0),
      );
      await tester.pump();
      final value =
          container.read(readerSettingsRepositoryProvider).current.nightBrightness;
      expect(value, lessThan(1.0), reason: '左拖应调暗（最小 0.8）');
      expect(value, greaterThanOrEqualTo(0.8));
    });

    testWidgets('翻页动画（B5）：滚动模式不显示，分页模式可选左右翻页并持久化',
        (tester) async {
      await pumpPanel(tester);
      // 出厂分页：动画选择器可见；切滚动后隐藏。
      expect(
        find.byKey(const ValueKey('settings-page-turn-axis')),
        findsOneWidget,
      );
      await tester.dragUntilVisible(
        find.text('翻页模式'),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('滚动').last);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('settings-page-turn-axis')),
        findsNothing,
        reason: '翻页动画仅分页模式有意义（原型行为）',
      );

      // 切回分页，选左右翻页并验证持久化。
      await tester.tap(find.text('分页').last);
      await tester.pump();
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('settings-page-turn-axis')),
        panelScroller(),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('左右翻页').last);
      await tester.pump();
      final repo = container.read(readerSettingsRepositoryProvider);
      expect(repo.current.pageTurnAxis, ReaderPageTurnAxis.horizontal);
      final raw = await db.readerSettingsDao.getValue(
        ReaderSettingsRepository.storageKey,
      );
      expect(raw, contains('"pageTurnAxis":"horizontal"'));
    });
  });
}
