/// 应用外壳（AppShell）widget 测试（docs/10 §4.1 / A1）：
///
/// - 宽窗口（1440×900）：232px 侧栏，品牌区 + 三项导航 + 同步胶囊，
///   当前项按路由前缀高亮；
/// - 窄窗口（900×700）：68px 图标栏（无文字标签、无品牌文字）；
/// - 手机窗口（390×844）：侧栏隐藏，底部标签栏三项。
///
/// 用 stub 页面的独立路由测试外壳本身；真实路由装配由 app_test 覆盖。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/shell/app_shell.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester,
    GoRouter router,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          darkTheme: AppTheme.dark(AppAccent.terracotta),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('页面-书库')),
          ),
          GoRoute(
            path: '/book/:bookId',
            builder: (_, _) => const Scaffold(body: Text('页面-详情')),
          ),
          GoRoute(
            path: '/sync/settings',
            builder: (_, _) => const Scaffold(body: Text('页面-同步')),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, _) => const Scaffold(body: Text('页面-设置')),
          ),
        ],
      ),
    ],
  );

  /// 找包住 [label] 文字的最近 Material（导航项底色载体）：选中态 =
  /// brandSoft，未选中 = transparent。
  Color? railItemColor(WidgetTester tester, String label) {
    final materials = tester.widgetList<Material>(
      find.ancestor(of: find.text(label), matching: find.byType(Material)),
    );
    return materials.isEmpty ? null : materials.first.color;
  }

  group('宽窗口 1440×900（232px 侧栏）', () {
    testWidgets('品牌区、主导航分组标签与三项导航、同步胶囊都渲染', (tester) async {
      await pumpShell(tester, buildRouter(), const Size(1440, 900));
      expect(find.text('页面-书库'), findsOneWidget);
      expect(find.text('SyncReader'), findsOneWidget);
      expect(find.text('主导航'), findsOneWidget);
      expect(find.text('书库'), findsOneWidget);
      expect(find.text('同步'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      // 同步胶囊：默认内存状态为「未配置」。
      expect(find.text('未配置'), findsOneWidget);
      // 侧栏宽度 232。
      final rail = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container && w.constraints?.maxWidth == AppLayout.railWidth,
        ),
      );
      expect(rail, isNotEmpty);
    });

    testWidgets('默认选中书库（/ 前缀），切到 /settings 后高亮跟随', (tester) async {
      final router = buildRouter();
      await pumpShell(tester, router, const Size(1440, 900));
      final t = Theme.of(tester.element(find.text('书库')))
          .extension<AppDesignTokens>()!;
      // 书库选中（brandSoft 底），设置未选中。
      expect(railItemColor(tester, '书库'), t.brandSoft);
      expect(railItemColor(tester, '设置'), Colors.transparent);

      router.go('/settings');
      await tester.pumpAndSettle();
      expect(find.text('页面-设置'), findsOneWidget);
      expect(railItemColor(tester, '设置'), t.brandSoft);
      expect(railItemColor(tester, '书库'), Colors.transparent);

      // /book/:bookId 归书库组。
      router.go('/book/abc');
      await tester.pumpAndSettle();
      expect(find.text('页面-详情'), findsOneWidget);
      expect(railItemColor(tester, '书库'), t.brandSoft);

      // /sync/* 归同步组。
      router.go('/sync/settings');
      await tester.pumpAndSettle();
      expect(find.text('页面-同步'), findsOneWidget);
      expect(railItemColor(tester, '同步'), t.brandSoft);
    });

    testWidgets('点击导航与同步胶囊都能切换路由', (tester) async {
      final router = buildRouter();
      await pumpShell(tester, router, const Size(1440, 900));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('页面-设置'), findsOneWidget);

      // 点击底部同步胶囊 → 同步设置页。
      await tester.tap(find.text('未配置'));
      await tester.pumpAndSettle();
      expect(find.text('页面-同步'), findsOneWidget);
    });
  });

  group('窄窗口 900×700（68px 图标栏）', () {
    testWidgets('只留图标：无导航文字、无品牌文字、无胶囊文字', (tester) async {
      await pumpShell(tester, buildRouter(), const Size(900, 700));
      expect(find.text('页面-书库'), findsOneWidget);
      // 文字标签全部隐藏（原型 3013-3016 行）。
      expect(find.text('书库'), findsNothing);
      expect(find.text('同步'), findsNothing);
      expect(find.text('设置'), findsNothing);
      expect(find.text('SyncReader'), findsNothing);
      expect(find.text('主导航'), findsNothing);
      expect(find.text('未配置'), findsNothing);
      // 侧栏宽度收成 68。
      final rail = tester.widgetList<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.constraints?.maxWidth == AppLayout.railNarrowWidth,
        ),
      );
      expect(rail, isNotEmpty);
    });

    testWidgets('点图标仍可导航', (tester) async {
      await pumpShell(tester, buildRouter(), const Size(900, 700));
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      expect(find.text('页面-设置'), findsOneWidget);
    });
  });

  group('手机窗口 390×844（底部标签栏）', () {
    testWidgets('无侧栏，底栏三项标签', (tester) async {
      await pumpShell(tester, buildRouter(), const Size(390, 844));
      expect(find.text('页面-书库'), findsOneWidget);
      // 侧栏（宽/窄两种）都不存在。
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              (w.constraints?.maxWidth == AppLayout.railWidth ||
                  w.constraints?.maxWidth == AppLayout.railNarrowWidth),
        ),
        findsNothing,
      );
      expect(find.text('SyncReader'), findsNothing);
      // 底部标签栏：图标 + 标签。
      expect(find.text('书库'), findsOneWidget);
      expect(find.text('同步'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
    });

    testWidgets('点标签切换页面', (tester) async {
      await pumpShell(tester, buildRouter(), const Size(390, 844));
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      expect(find.text('页面-设置'), findsOneWidget);
      await tester.tap(find.text('同步'));
      await tester.pumpAndSettle();
      expect(find.text('页面-同步'), findsOneWidget);
    });
  });
}
