/// 同步设置页布局锁定测试：480x800 / 1280x800 两种窗口尺寸下整页渲染
/// 无溢出异常（RenderFlex 溢出在测试中即 exception，天然断言）。
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
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  Future<void> pumpPage(WidgetTester tester, {required bool configured}) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    addTearDown(db.close);
    if (configured) {
      await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
      await credentials.save(SecureKeys.webdavPassword, 'app-secret');
      await credentials.save(
        SecureKeys.webdavBaseUrl,
        'https://dav.example.com/dav/',
      );
      await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
    }
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
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SyncSettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    credentials = InMemoryCredentialStore();
  });

  for (final (size, label) in const [
    (Size(480, 800), '480x800 窄窗'),
    (Size(1280, 800), '1280x800 宽窗'),
  ]) {
    testWidgets('$label · 未配置态无溢出异常', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, configured: false);
      expect(tester.takeException(), isNull);
      expect(find.text('后端未配置'), findsOneWidget);
    });

    testWidgets('$label · 已配置态（含配额面板/开关）无溢出异常', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, configured: true);
      expect(tester.takeException(), isNull);
      expect(find.text('坚果云 WebDAV'), findsOneWidget);
    });
  }
}

/// 未配置适配器（布局测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
