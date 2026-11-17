/// 配额面板 widget 测试（A12 / FR-407 / docs/04 §8.3 UI 呈现）：
/// <80% 正常态、≥80% 超限提示条 + 80% 刻度线、100% 挂起文案与「配额越权」
/// 开关（二次确认后放行）。quota 快照直接构造注入（quotaSnapshotProvider
/// override）。
///
/// A12 选择器更新记录（语义不变）：
/// - 用量文案 `100 MB（10%）` → 原型 `100 MB · 10%`；
/// - 警示条从面板标题上方移到双条下方（原型 .quota 内 notice）；
/// - 越权入口从「继续下载」按钮改为「配额越权」开关行（二次确认保留）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/quota_gate.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_preferences.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  /// 泵设置页并注入 quota 快照。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester,
    QuotaSnapshot snapshot,
  ) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        syncAdapterProvider.overrideWithValue(
          const _UnconfiguredAdapterProvider(),
        ),
        quotaSnapshotProvider.overrideWith((ref) async => snapshot),
      ],
    );
    // 页面 watch 了 drift 流（书数 / 仅本地的书）：关库收尾需先注册
    // （addTearDown LIFO → 最后执行），让 container.dispose 先取消流订阅；
    // 再排空 drift 定时器并在真实区关库（与 orphan_files_page_test 一致，
    // 顺序颠倒会让 db.close 挂起）。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(db.close);
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(AppAccent.terracotta),
          home: const SyncSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('正常态（<80%）：用量/百分比可见，无警示条', (tester) async {
    final container = await pumpPage(
      tester,
      const QuotaSnapshot(
        upBytes: 100 * 1024 * 1024,
        downBytes: 512 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    // 上行/下行用量与百分比（相对可配置额度，原型 `值 · 百分比` 格式）。
    expect(find.text('100 MB · 10%'), findsOneWidget);
    expect(find.text('512 MB · 17%'), findsOneWidget);
    expect(find.textContaining('2026-10'), findsOneWidget);
    // 无警示条。
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(container.read(syncPreferencesProvider).quotaOverride, isFalse);
  });

  testWidgets('≥80%：面板内超限提示条（双条下方）+ 80% 刻度线 + 用量胶囊', (tester) async {
    await pumpPage(
      tester,
      const QuotaSnapshot(
        upBytes: 0,
        downBytes: 2560 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    expect(find.textContaining('本月同步流量已超过 80%，自动下载已暂停'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    // 头部用量胶囊（取上行/下行较大者）。
    expect(find.text('已用 83%'), findsOneWidget);
    // 提示条位于「下行」条目下方（原型 notice 在 bars 之后）。
    final downLabelTop = tester.getTopLeft(find.text('下行（云端正文下载）')).dy;
    final noticeTop = tester.getTopLeft(find.textContaining('本月同步流量已超过 80%')).dy;
    expect(noticeTop, greaterThan(downLabelTop));
    // 未达 100%：无挂起文案。
    expect(find.textContaining('正文传输已全部挂起'), findsNothing);
  });

  testWidgets('100%：挂起文案 + 配额越权开关（二次确认放行/关闭恢复闸门）', (tester) async {
    final container = await pumpPage(
      tester,
      const QuotaSnapshot(
        upBytes: 0,
        downBytes: 3 * 1024 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    expect(find.textContaining('正文传输已全部挂起'), findsOneWidget);

    // 越权需明确二次确认（docs/04 §8.3）：第三个开关 = 「配额越权」。
    await tester.tap(find.byType(SwitchListTile).at(2));
    await tester.pumpAndSettle();
    expect(find.text('本月流量已达上限'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '继续下载'));
    await tester.pumpAndSettle();

    // 越权生效：开关行说明切换为已放行文案。
    expect(container.read(syncPreferencesProvider).quotaOverride, isTrue);
    expect(find.textContaining('本月正文下载将继续'), findsOneWidget);

    // 关闭开关 = 恢复闸门。
    await tester.tap(find.byType(SwitchListTile).at(2));
    await tester.pumpAndSettle();
    expect(container.read(syncPreferencesProvider).quotaOverride, isFalse);
    expect(find.textContaining('正文传输已全部挂起'), findsOneWidget);
  });
}

/// 未配置适配器（面板测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
