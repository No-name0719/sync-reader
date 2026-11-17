/// 全局同步状态横幅的 80% 常驻提醒链路测试（docs/04 §8.3）：
/// 内存侧实时告警优先；快照推导兜底（冷启动未同步也常驻）；无告警不显示。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/quota_gate.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_status.dart';
import 'package:sync_reader/features/sync/widgets/sync_status_banner.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  Future<ProviderContainer> pumpBanner(
    WidgetTester tester, {
    QuotaSnapshot? snapshot,
  }) async {
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
        if (snapshot != null)
          quotaSnapshotProvider.overrideWith((ref) async => snapshot),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: SyncStatusBanner())),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  testWidgets('内存侧实时告警：空闲态横幅直接显示告警文案', (tester) async {
    final container = await pumpBanner(tester);
    container
        .read(syncMemoryStatusProvider.notifier)
        .applyOutcome(
          const SyncStatusOutcome(
            stateId: SyncStateId.idle,
            quotaWarnText: '本月同步流量已超过 80%，自动下载已暂停',
          ),
        );
    await tester.pump();
    expect(find.textContaining('80%'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('快照推导兜底：内存无告警时由持久化配额快照常驻提醒', (tester) async {
    final container = await pumpBanner(
      tester,
      snapshot: const QuotaSnapshot(
        downBytes: 2560 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    // 先切到空闲态（默认为 unconfigured，不替换横幅文案）。
    container
        .read(syncMemoryStatusProvider.notifier)
        .applyOutcome(const SyncStatusOutcome(stateId: SyncStateId.idle));
    await tester.pump();
    expect(find.textContaining('80%'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('未达告警线：横幅保持常规状态文案，无警示图标', (tester) async {
    final container = await pumpBanner(
      tester,
      snapshot: const QuotaSnapshot(
        downBytes: 512 * 1024 * 1024,
        month: '2026-10',
      ),
    );
    // 切到空闲态（默认为 unconfigured），快照未达 80% → 常规文案。
    container
        .read(syncMemoryStatusProvider.notifier)
        .applyOutcome(const SyncStatusOutcome(stateId: SyncStateId.idle));
    await tester.pump();
    expect(find.text('同步空闲'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
  });
}

/// 未配置适配器（横幅测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
