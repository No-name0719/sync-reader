/// 同步设置页布局锁定测试：480x800 / 1280x800 / 390x844 / 860x900 /
/// 1440x900 多种窗口尺寸下整页渲染无溢出异常（RenderFlex 溢出在测试中即
/// exception，天然断言）。A12：390/860/1440 为新增三档（移动/半窗/桌面）。
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
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  Future<void> pumpPage(WidgetTester tester, {required bool configured}) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    // 页面 watch 了 drift 流（书数 / 仅本地的书）：关库收尾需先注册
    // （addTearDown LIFO → 最后执行），让 container.dispose 先取消流订阅；
    // 再排空 drift 定时器并在真实区关库（与 orphan_files_page_test 一致，
    // 顺序颠倒会让 db.close 挂起）。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(db.close);
    });
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
        child: MaterialApp(
          theme: AppTheme.light(AppAccent.terracotta),
          home: const SyncSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    credentials = InMemoryCredentialStore();
  });

  for (final (size, label) in const [
    (Size(390, 844), '390x844 移动窗'),
    (Size(480, 800), '480x800 窄窗'),
    (Size(860, 900), '860x900 半窗'),
    (Size(1280, 800), '1280x800 宽窗'),
    (Size(1440, 900), '1440x900 桌面窗'),
  ]) {
    testWidgets('$label · 未配置态无溢出异常', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpPage(tester, configured: false);
      expect(tester.takeException(), isNull);
      expect(find.text('未配置'), findsOneWidget);
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
