/// 配额面板 widget 测试（C2b / FR-407 / docs/04 §8.3 UI 呈现）：
/// <80% 正常态、≥80% 顶部常驻警示条、100% 挂起文案与越权放行/恢复闸门。
/// quota 快照直接构造注入（quotaSnapshotProvider override）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
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
    addTearDown(container.dispose);
    addTearDown(db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SyncSettingsPage()),
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
    // 上行/下行用量与百分比（相对可配置额度）。
    expect(find.text('100 MB（10%）'), findsOneWidget);
    expect(find.text('512 MB（17%）'), findsOneWidget);
    expect(find.textContaining('2026-10'), findsOneWidget);
    // 无警示条。
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(container.read(syncPreferencesProvider).quotaOverride, isFalse);
  });

  testWidgets('≥80%：面板顶部常驻警示条（80% 提醒入口）', (tester) async {
    await pumpPage(
      tester,
      const QuotaSnapshot(
        upBytes: 0,
        downBytes: 2560 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    expect(find.text('坚果云流量已用超 80%，自动下载已暂停；元数据同步不受影响'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    // 警示条位于面板标题（"本月流量"）上方：面板顶部常驻。
    final bannerTop = tester.getTopLeft(
      find.text('坚果云流量已用超 80%，自动下载已暂停；元数据同步不受影响'),
    );
    final titleTop = tester.getTopLeft(find.textContaining('本月流量'));
    expect(bannerTop.dy, lessThan(titleTop.dy));
    // 未达 100%：无越权入口。
    expect(find.text('继续下载（流量已超限）'), findsNothing);
  });

  testWidgets('100%：挂起文案 + 越权放行二次确认 + 恢复闸门', (tester) async {
    final container = await pumpPage(
      tester,
      const QuotaSnapshot(
        upBytes: 0,
        downBytes: 3 * 1024 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    expect(find.text('正文传输已全部挂起，可在下方越权继续（将消耗坚果云额度）'), findsOneWidget);
    expect(find.text('继续下载（流量已超限）'), findsOneWidget);

    // 越权需明确二次确认（docs/04 §8.3）。
    await tester.tap(find.text('继续下载（流量已超限）'));
    await tester.pumpAndSettle();
    expect(find.text('本月流量已达上限'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '继续下载'));
    await tester.pumpAndSettle();

    // 越权生效：与警示关联展示 + 可恢复闸门。
    expect(container.read(syncPreferencesProvider).quotaOverride, isTrue);
    expect(find.textContaining('已越权放行'), findsOneWidget);
    expect(find.text('恢复闸门'), findsOneWidget);

    // 恢复闸门：回到挂起态。
    await tester.tap(find.text('恢复闸门'));
    await tester.pumpAndSettle();
    expect(container.read(syncPreferencesProvider).quotaOverride, isFalse);
    expect(find.text('继续下载（流量已超限）'), findsOneWidget);
  });
}

/// 未配置适配器（面板测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
