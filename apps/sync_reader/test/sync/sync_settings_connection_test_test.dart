/// 同步设置页「测试连接」按钮测试（v1.1：点一下就测已保存的后端配置）：
///
/// 1. 已配置 → 后端卡渲染「测试连接」（主色）+「重新配置」（文字钮）；
/// 2. 点「测试连接」→ 发起一次真实"测试调用"（经可注入的
///    [connectionTestRunnerProvider] 假实现断言确实发起）→ 结果就地显示
///    在后端卡内（成功态：连接正常 + 延迟 + 能力摘要；失败态：失败文案 +
///    步骤明细）；
/// 3. 未配置 → 点「测试连接」→ 就地提示「尚未配置后端」且**未发起任何测试**；
/// 4. 只测不改：测试后凭据与连接状态胶囊不受影响；
/// 5. 再次点击即重测：结果区整体刷新（不叠加多个结果块）。
///
/// 说明：[ConnectionTester] 是 final class 不可子类化，故测试经
/// `connectionTestRunnerProvider` 注入假执行器（不碰网络）。
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
import 'package:sync_reader/features/sync/connection_test.dart';
import 'package:sync_reader/features/sync/connection_test_runner.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  setUp(() {
    credentials = InMemoryCredentialStore();
  });

  /// 泵同步设置页（可注入假连接测试执行器）。
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required bool configured,
    ConnectionTestRunner? runner,
  }) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
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
        if (runner != null)
          connectionTestRunnerProvider.overrideWithValue(runner),
      ],
    );
    // 页面 watch 了 drift 流（书数 / 仅本地的书）：关库收尾需先注册
    // （addTearDown LIFO → 最后执行），让 container.dispose 先取消流订阅；
    // 再排空 drift 定时器并在真实区关库（与既有设置页测试一致）。
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

  testWidgets('已配置：后端卡渲染「测试连接」+「重新配置」两个按钮', (tester) async {
    await pumpPage(tester, configured: true);
    expect(find.widgetWithText(FilledButton, '测试连接'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '重新配置'), findsOneWidget);
    // 未配置态的「去配置」入口此时不出现。
    expect(find.widgetWithText(OutlinedButton, '去配置'), findsNothing);
  });

  testWidgets('点「测试连接」：发起测试并就地展示成功结果（连接正常 + 能力摘要）', (tester) async {
    final fake = _FakeRunner(_successResult());
    await pumpPage(tester, configured: true, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    // 确实发起了一次测试，且用的是已保存的配置。
    expect(fake.calls, 1);
    expect(fake.lastUsername, 'user@example.com');
    expect(fake.lastPassword, 'app-secret');
    expect(fake.lastBaseUrl, 'https://dav.example.com/dav');
    expect(fake.lastRootPath, '/Apps/SyncReader');

    // 结果就地显示在后端卡内（不进弹窗、不跳页）。
    expect(find.text('连接正常 · 列目录 274 ms'), findsOneWidget);
    expect(find.text('MOVE 支持 · ETag 支持 · Range 支持'), findsOneWidget);
    expect(find.text('连接失败'), findsNothing);
  });

  testWidgets('测试失败：就地展示失败文案与步骤明细（步骤 / 状态码 / 延迟）', (tester) async {
    final fake = _FakeRunner(_failureResult());
    await pumpPage(tester, configured: true, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    expect(fake.calls, 1);
    expect(find.text('连接失败'), findsOneWidget);
    expect(find.textContaining('密码错误或账号无效'), findsOneWidget);
    // 步骤明细：哪一步失败 + 状态码 + 延迟。
    expect(find.text('写探针文件'), findsOneWidget);
    expect(find.text('HTTP 401'), findsOneWidget);
    expect(find.text('88 ms'), findsOneWidget);
  });

  testWidgets('未配置：点「测试连接」→ 提示「尚未配置后端」且未发起任何测试', (tester) async {
    final fake = _FakeRunner(_successResult());
    await pumpPage(tester, configured: false, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    expect(fake.calls, 0, reason: '未配置时不得发起任何请求');
    expect(find.text('尚未配置后端'), findsOneWidget);
    expect(find.text('连接正常 · 列目录 274 ms'), findsNothing);
  });

  testWidgets('只测不改：测试后凭据与连接状态胶囊不受影响', (tester) async {
    final fake = _FakeRunner(_failureResult());
    await pumpPage(tester, configured: true, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    // 凭据原样保留（不写、不清、不覆盖）。
    expect(
      await credentials.read(SecureKeys.webdavAccount),
      'user@example.com',
    );
    expect(await credentials.read(SecureKeys.webdavPassword), 'app-secret');
    // 连接状态胶囊不受测试结果影响（仍是「已连接」）。
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('再次点击即重测：结果区整体刷新（不叠加多个结果块）', (tester) async {
    final fake = _FakeRunner(_successResult());
    await pumpPage(tester, configured: true, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();
    expect(fake.calls, 1);

    // 第二次点击：换成失败结果，旧结果块应被替换而不是叠加。
    fake.result = _failureResult();
    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    expect(fake.calls, 2);
    expect(find.text('连接正常 · 列目录 274 ms'), findsNothing);
    expect(find.text('连接失败'), findsOneWidget);
  });

  testWidgets('390x844 窄窗：按钮行与结果卡无溢出异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fake = _FakeRunner(_failureResult());
    await pumpPage(tester, configured: true, runner: fake.call);

    await tester.tap(find.widgetWithText(FilledButton, '测试连接'));
    await tester.pump();
    await tester.pump();

    expect(find.text('连接失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 假连接测试执行器（记录调用次数与参数；不碰网络）。
class _FakeRunner {
  _FakeRunner(this.result);

  /// 本次要返回的结果（测试中可替换，模拟重测）。
  ConnectionTestResult result;

  int calls = 0;
  String? lastBaseUrl;
  String? lastUsername;
  String? lastPassword;
  String? lastRootPath;

  Future<ConnectionTestResult> call({
    required String baseUrl,
    required String username,
    required String password,
    String? rootPath,
  }) async {
    calls++;
    lastBaseUrl = baseUrl;
    lastUsername = username;
    lastPassword = password;
    lastRootPath = rootPath;
    return result;
  }
}

/// 成功结果（含能力摘要）。
ConnectionTestResult _successResult() => const ConnectionTestResult(
  steps: [
    ConnectionTestStep(name: '列目录', ok: true, latencyMs: 274),
    ConnectionTestStep(name: '写探针文件', ok: true, latencyMs: 91),
  ],
  success: true,
  capabilities: BackendCapabilities(
    supportsMove: true,
    supportsEtag: true,
    supportsRange: true,
  ),
);

/// 失败结果（含失败文案与失败步骤明细）。
ConnectionTestResult _failureResult() => const ConnectionTestResult(
  steps: [
    ConnectionTestStep(name: '列目录', ok: true, latencyMs: 120),
    ConnectionTestStep(
      name: '写探针文件',
      ok: false,
      latencyMs: 88,
      detail: 'HTTP 401',
    ),
  ],
  success: false,
  failureText: '密码错误或账号无效（HTTP 401）：请核对后重新输入',
);

/// 未配置适配器（设置页测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
