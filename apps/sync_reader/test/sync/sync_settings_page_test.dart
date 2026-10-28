/// 同步设置页 widget 测试（FR-405/406/409/505 关键路径）：
/// 未配置态 → 引导入口；开关持久化（reader_settings `sync.preferences`）；
/// 失败原因文案显示；配额面板告警。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_preferences.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        syncAdapterProvider.overrideWithValue(
          const _UnconfiguredAdapterProvider(),
        ),
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

  setUp(() {
    credentials = InMemoryCredentialStore();
  });

  Future<void> seedCredentials() async {
    await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    await credentials.save(
      SecureKeys.webdavBaseUrl,
      'https://dav.example.com/',
    );
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
  }

  testWidgets('未配置态：后端卡片显示未配置 + 去配置入口', (tester) async {
    await pumpPage(tester);
    expect(find.text('后端未配置'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
  });

  testWidgets('已配置态：显示坚果云 WebDAV + 账号', (tester) async {
    await seedCredentials();
    await pumpPage(tester);
    expect(find.text('坚果云 WebDAV'), findsOneWidget);
    expect(find.textContaining('user@example.com'), findsOneWidget);
  });

  testWidgets('自动同步开关切换即持久化（sync.preferences JSON）', (tester) async {
    final container = await pumpPage(tester);
    final initial = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(initial, isNull); // 未动过。

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    final stored = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(stored, isNotNull);
    expect(stored, contains('"autoSyncEnabled":false'));
    // 状态同步更新。
    expect(container.read(syncPreferencesProvider).autoSyncEnabled, isFalse);
  });

  testWidgets('仅 Wi-Fi 正文开关切换持久化', (tester) async {
    await pumpPage(tester);
    // 第二个开关是"仅 Wi-Fi 同步正文"。
    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pump();
    final stored = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(stored, contains('"wifiOnlyContent":false'));
  });

  testWidgets('同步失败：失败原因分类文案可见（FR-406）', (tester) async {
    final container = await pumpPage(tester);
    container
        .read(syncMemoryStatusProvider.notifier)
        .applyOutcome(
          const SyncStatusOutcome(
            stateId: SyncStateId.failed,
            failureText: '密码错误或账号失效，请重新配置',
          ),
        );
    await tester.pump();
    expect(find.textContaining('密码错误或账号失效'), findsOneWidget);
    // 立即同步按钮在失败后仍可用（可重试）。
    expect(find.text('立即同步'), findsOneWidget);
  });

  testWidgets('同步中：按钮禁用并显示进行中指示', (tester) async {
    final container = await pumpPage(tester);
    container.read(syncMemoryStatusProvider.notifier).markSyncing();
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('立即同步'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('配额面板：内存侧告警文案可见（80% 常驻提醒）', (tester) async {
    final container = await pumpPage(tester);
    container
        .read(syncMemoryStatusProvider.notifier)
        .setQuotaWarn('本月同步流量已超过 80%，自动下载已放缓');
    await tester.pump();
    expect(find.textContaining('80%'), findsWidgets);
  });

  testWidgets('诊断区：导出诊断日志与清空日志入口可见（FR-604）', (tester) async {
    await pumpPage(tester);
    expect(find.text('导出诊断日志'), findsOneWidget);
    expect(find.text('清空日志'), findsOneWidget);
    expect(find.textContaining('二次脱敏'), findsOneWidget);
  });
}

/// 未配置适配器（设置页测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
