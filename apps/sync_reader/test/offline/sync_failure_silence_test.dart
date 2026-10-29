/// FR-601 网络恢复补同步 + 同步报错静默性专项。
///
/// - 用例 5（弱网重试路径的容器内替代）：connectivity none → wifi 触发
///   "网络恢复全量"（docs/04 §3 触发时机 4），同步结果落 FR-406 状态而非弹窗；
/// - 用例 6：让同步门面抛 SyncError（网络不可达 / 401 两类），分别在书库与
///   阅读页观察：全程无 showDialog / 阻塞 SnackBar（ScaffoldMessenger 计数
///   为 0），失败只进状态横幅/内存状态，阅读不被打断。
///
/// 注入手法：connectivity 经 OfflineEnv 广播流注入 SyncTriggers；云端用
/// FailingBackendAdapter（凭据配置齐全、引擎可构建、操作必败，零真实网络）。
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/library/library_page.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/reader_page.dart';
import 'package:sync_reader/features/sync/sync_status.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

import 'offline_env.dart';

void main() {
  // ── 用例 5：网络恢复后补同步（none → wifi）────────────────────────────

  testWidgets('none → wifi 触发网络恢复全量：失败落状态横幅而非弹窗', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    await env.configureCredentials();
    final failing = FailingBackendAdapter(const NetworkUnreachable('网络不可达'));

    await pumpOfflineApp(
      tester,
      env,
      adapterProvider: FixedAdapterProvider(failing),
    );
    await tester.pump();
    // 飞行模式：无网络认知，不发起任何同步。
    env.connectivity.add(const [ConnectivityResult.none]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(env.recorder.sources, isEmpty, reason: '飞行模式下不得触发同步');

    // 网络恢复：none → wifi 触发一次 networkRestored 全量（触发器测试
    // 已验证触发语义，这里验证容器内的端到端接线与结果落状态）。
    env.connectivity.add(const [ConnectivityResult.wifi]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    // 同步被触发（且总耗时 < 2s，启动定时器尚未介入，序列精确）。
    expect(env.recorder.sources, [SyncTriggerSource.networkRestored]);
    // 云端确实被尝试（引擎构建 + 首阶段失败），失败而非未发生。
    expect(failing.connectCalls, greaterThanOrEqualTo(1));
    expect(failing.ensureLayoutCalls, 1);
    // 结果落状态：failed + 分类文案（FR-406），不弹任何阻塞 UI。
    // （v1.1 A3：常驻状态横幅移出书库内容区，容器取自书库页元素；
    // 失败态由书库顶部的可关闭提示条呈现。）
    final memory = ProviderScope.containerOf(
      tester.element(find.byType(LibraryPage)),
    ).read(syncMemoryStatusProvider);
    expect(memory.id, SyncStateId.failed);
    expect(memory.failureText, '网络不可达，请检查网络连接');
    // 状态横幅（非阻塞）承载失败文案；全程零弹窗零 SnackBar。
    expect(find.textContaining('同步失败'), findsOneWidget);
    expect(find.textContaining('网络不可达'), findsOneWidget);
    expectNoBlockingErrorUi(tester);

    await shutdownOfflineApp(tester, env);
  });

  // ── 用例 6：同步报错静默性专项 ─────────────────────────────────────────

  testWidgets('网络不可达：书库页手动同步失败只进状态横幅，无弹窗无 SnackBar', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    await env.configureCredentials();
    final failing = FailingBackendAdapter(const NetworkUnreachable('网络不可达'));
    final container = env.makeContainer(
      adapterProvider: FixedAdapterProvider(failing),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        // v1.1 A2/A3：书库页消费设计令牌，测试骨架挂 AppTheme。
        child: MaterialApp(
          theme: AppTheme.light(AppAccent.terracotta),
          home: const LibraryPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // 手动触发一轮必败同步（触发器 manualSync 入口，同下拉刷新路径）。
    await container.read(syncTriggersProvider).manualSync();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 失败落书库顶部提示条（非阻塞，A3），无对话框无 SnackBar。
    expect(find.textContaining('同步失败'), findsOneWidget);
    expect(find.textContaining('网络不可达'), findsOneWidget);
    expectNoBlockingErrorUi(tester, reason: '（书库页 + 网络不可达）');
    // 同步入口确有记录（manual 来源）。
    expect(env.recorder.sources, [SyncTriggerSource.manual]);

    await shutdownWithContainer(tester, env, container);
  });

  testWidgets('401 认证失效：阅读页打开后同步失败静默，阅读不被打断', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    await env.configureCredentials();
    // 401 → AuthFailedSyncError（syncErrorText 分类文案）。
    final failing = FailingBackendAdapter(
      const BackendRequestException('HTTP 401 Unauthorized', statusCode: 401),
    );
    // 阅读页用零 IO 假渲染器（手法同 test/features/reader/integration）。
    final container = env.makeContainer(
      adapterProvider: FixedAdapterProvider(failing),
      registry: FormatRegistry()..register(OfflineFakeHandler()),
    );
    await env.db.booksDao.upsertCompanion(
      bookRow('offlinebook04', title: '认证失效阅读书'),
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReaderPage(bookId: 'offlinebook04')),
      ),
    );
    // 两帧：首帧挂载 + microtask 排空（打开链路完成，假渲染器无 IO）。
    await tester.pump();
    await tester.pump();

    // 阅读页正常就绪（打开链路与同步完全解耦）。
    expect(
      find.byKey(const ValueKey('offline-fake-renderer-view')),
      findsOneWidget,
    );
    expect(find.text('认证失效阅读书'), findsOneWidget);

    // 阅读期间同步失败（401）。
    await container.read(syncTriggersProvider).manualSync();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 失败进内存状态（FR-406 分类文案），不出现在阅读页 UI 上。
    final memory = container.read(syncMemoryStatusProvider);
    expect(memory.id, SyncStateId.failed);
    expect(memory.failureText, '密码错误或账号失效，请重新配置');
    // 阅读不被打断：渲染视图仍在，无弹窗无 SnackBar。
    expect(
      find.byKey(const ValueKey('offline-fake-renderer-view')),
      findsOneWidget,
    );
    expectNoBlockingErrorUi(tester, reason: '（阅读页 + 401）');

    await shutdownWithContainer(tester, env, container);
  });
}

/// 手动容器的用例收尾：先卸载 widget 树，再同步销毁容器（释放 provider
/// 持有的 drift 流查询——否则 db.close 会等待流清理而挂起），排空残余
/// fake 定时器后，最后在真实区清理环境。
Future<void> shutdownWithContainer(
  WidgetTester tester,
  OfflineEnv env,
  ProviderContainer container,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  container.dispose();
  await tester.pump(const Duration(seconds: 60));
  await tester.runAsync(env.dispose);
}
