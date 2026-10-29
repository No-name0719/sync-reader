/// 设置页（A15）widget 测试：四区渲染、accent/外观模式即时生效、
/// 持久化落库与「重启」读回、阅读默认值编辑、清理缓存流程。
///
/// 存储/清理的真实文件 IO 在 fakeAsync 区无法完成：
/// - 统计经 `storageUsageProvider.overrideWith` 注入固定值（真实计算逻辑
///   由 storage_usage_test 用临时目录单测覆盖）；
/// - 清理动作经 `tmpCacheCleanerProvider.overrideWithValue` 注入假动作。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/app_preferences.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/core/version.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/reader_settings_repository.dart';
import 'package:sync_reader/features/settings/settings_page.dart';
import 'package:sync_reader/features/settings/storage_usage.dart';

/// 主题探针：跟随 accent / 外观模式 provider 的 MaterialApp（复现 app.dart
/// 的装配；设置页直接作 home，测试从页面元素读当前主题令牌）。
class _ThemeProbe extends ConsumerWidget {
  const _ThemeProbe({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(appAccentProvider);
    final mode = ref.watch(appThemeModeProvider);
    return MaterialApp(
      theme: AppTheme.light(accent),
      darkTheme: AppTheme.dark(accent),
      themeMode: mode,
      home: child,
    );
  }
}

void main() {
  late AppDatabase db;
  Directory? tmp;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
  });

  tearDown(() async {
    if (tmp != null && tmp!.existsSync()) {
      await tmp!.delete(recursive: true);
      tmp = null;
    }
  });

  /// 建 tmp 目录（需要真实路径的用例才调用）。
  Future<void> makeTmp(WidgetTester tester) async {
    await tester.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('settings_page_test');
      await BookFileStore(tmp!).ensureLayout();
    });
  }

  /// 卸载 widget 树并排空 drift 定时器（不关库；重启模拟用）。
  Future<void> unloadOnly(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 60));
  }

  /// 收尾：卸载后关闭库（残留 drift 定时器不排空会让测试级联挂起）。
  Future<void> shutdown(WidgetTester tester) async {
    await unloadOnly(tester);
    await tester.runAsync(() async => db.close());
  }

  Future<void> pumpSettings(
    WidgetTester tester, {
    bool withHydration = false,
    Future<void> Function()? cleaner,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          if (tmp != null)
            bookFileStoreProvider.overrideWith(
              (ref) async => BookFileStore(tmp!),
            ),
          // 统计注入固定值：fakeAsync 区不能做真实目录遍历。
          storageUsageProvider.overrideWith(
            (ref) => const StorageUsage(
              booksBytes: 1024,
              coversBytes: 2048,
              tmpBytes: 4096,
            ),
          ),
          if (cleaner != null)
            tmpCacheCleanerProvider.overrideWithValue(cleaner),
        ],
        child: withHydration
            ? AppPreferencesHydrator(
                child: _ThemeProbe(child: const SettingsPage()),
              )
            : _ThemeProbe(child: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  AppDesignTokens tokensOf(WidgetTester tester, String label) =>
      Theme.of(tester.element(find.text(label))).extension<AppDesignTokens>()!;

  /// 在指定分段控件里点某个选项（同一页多处出现相同文案，必须限界）。
  Future<void> tapSegment(
    WidgetTester tester,
    Key buttonKey,
    String label,
  ) async {
    await tester.tap(
      find.descendant(of: find.byKey(buttonKey), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('四区卡片与关于信息渲染（外观/阅读/存储/关于）', (tester) async {
    await pumpSettings(tester);
    addTearDown(() => shutdown(tester));
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(find.text('存储'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    // 关于区：版本号与声明。
    expect(find.text('版本 $appVersion · MIT 开源许可 · 无账号 · 无遥测'), findsOneWidget);
    // 存储区：注入的统计值（1024/2048/4096 字节）。
    expect(find.text('books 目录 · 1.00 KB'), findsOneWidget);
    expect(find.text('covers 目录 · 2.00 KB'), findsOneWidget);
    expect(find.text('tmp 目录 · 4.00 KB'), findsOneWidget);
  });

  testWidgets('三套 accent 切换即时生效并落库 app.accent', (tester) async {
    await pumpSettings(tester);
    addTearDown(() => shutdown(tester));

    // 切到青瓷：主题令牌 accent 跟随。
    await tester.tap(find.text('青瓷'));
    await tester.pumpAndSettle();
    expect(tokensOf(tester, '外观').accent, AppAccent.teal);

    // 切到墨绿。
    await tester.tap(find.text('墨绿'));
    await tester.pumpAndSettle();
    expect(tokensOf(tester, '外观').accent, AppAccent.ink);

    // 落库：app_settings 表有 app.accent = ink。
    final stored = await tester.runAsync(
      () => db.appSettingsDao.getValue('app.accent'),
    );
    expect(stored, AppAccent.ink.name);

    // 切回赭石（默认）。
    await tester.tap(find.text('赭石'));
    await tester.pumpAndSettle();
    expect(tokensOf(tester, '外观').accent, AppAccent.terracotta);
    final stored2 = await tester.runAsync(
      () => db.appSettingsDao.getValue('app.accent'),
    );
    expect(stored2, AppAccent.terracotta.name);
  });

  testWidgets('外观模式切换即时生效并落库 app.theme_mode', (tester) async {
    await pumpSettings(tester);
    addTearDown(() => shutdown(tester));

    // 切深色：MaterialApp 改用 darkTheme。
    await tapSegment(tester, const ValueKey('app-settings-theme-mode'), '深色');
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.dark,
    );
    expect(tokensOf(tester, '外观').isDark, isTrue);

    final stored = await tester.runAsync(
      () => db.appSettingsDao.getValue('app.theme_mode'),
    );
    expect(stored, ThemeMode.dark.name);

    // 切回跟随系统（测试环境平台亮度为浅色）。
    await tapSegment(tester, const ValueKey('app-settings-theme-mode'), '跟随系统');
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.light,
    );
  });

  testWidgets('重启模拟：新容器经 AppPreferencesHydrator 读回相同 accent', (tester) async {
    addTearDown(() => shutdown(tester));

    // 第一「次启动」：切到墨绿（落库）。
    await pumpSettings(tester);
    await tester.tap(find.text('墨绿'));
    await tester.pumpAndSettle();
    await unloadOnly(tester);

    // 第二「次启动」：同一内存库 + 新 ProviderScope，经真实水合路径读回。
    await pumpSettings(tester, withHydration: true);
    expect(tokensOf(tester, '外观').accent, AppAccent.ink);
  });

  testWidgets('阅读区：字体与音量键翻页编辑落库 reader_settings 表', (tester) async {
    await pumpSettings(tester);
    addTearDown(() => shutdown(tester));

    // 默认字体 → 楷体。
    await tapSegment(tester, const ValueKey('app-settings-reader-font'), '楷体');
    // 音量键翻页开（长页面，先滚动到可见）。
    await tester.ensureVisible(
      find.byKey(const ValueKey('app-settings-volume-key')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-settings-volume-key')));
    await tester.pumpAndSettle();

    final raw = await tester.runAsync(
      () => db.readerSettingsDao.getValue(ReaderSettingsRepository.storageKey),
    );
    final settings = ReaderSettings.fromJson(
      jsonDecode(raw!) as Map<String, Object?>,
    );
    expect(settings.fontFamily, AppFonts.kai);
    expect(settings.volumeKeyPageTurn, isTrue);
  });

  testWidgets('390×844 手机宽度渲染无溢出（滚动查看）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpSettings(tester);
    addTearDown(() => shutdown(tester));
    expect(find.text('外观'), findsOneWidget);
    // 滚到页面底部也不溢出（渲染异常会让 testWidgets 直接失败）。
    await tester.scrollUntilVisible(
      find.text('SyncReader'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('清理缓存：确认弹窗后调用清理动作并提示', (tester) async {
    await makeTmp(tester);
    var called = 0;
    await pumpSettings(tester, cleaner: () async => called++);
    addTearDown(() => shutdown(tester));

    // 弹窗出现（弹窗标题与卡片行标题同文，共两处）。
    await tester.ensureVisible(
      find.byKey(const ValueKey('app-settings-clear-tmp')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-settings-clear-tmp')));
    await tester.pumpAndSettle();
    expect(find.text('清理缓存'), findsNWidgets(2));
    expect(find.textContaining('不影响书库与阅读进度'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 取消不清理。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(called, 0);

    // 确认清理 → 假动作被调用 + 轻提示。
    await tester.ensureVisible(
      find.byKey(const ValueKey('app-settings-clear-tmp')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-settings-clear-tmp')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('app-settings-clear-tmp-confirm')),
    );
    await tester.pumpAndSettle();
    expect(called, 1);
    expect(find.text('缓存已清理'), findsOneWidget);
    // SnackBar 收尾（定时器到点 + 退出动画），避免悬挂 Timer。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
