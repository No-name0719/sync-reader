/// FR-601 飞行模式全链路用例（docs/01 §3：无网络时阅读、翻书、导入全部
/// 正常，核心链路无网络调用报错弹窗）。
///
/// 本文件覆盖"完整应用骨架"（书库 → 详情 → 阅读器，真实页面 + 真实 txt
/// 渲染器）下的用户链路：
/// 1. 离线冷启动进书库（空库空态引导 / 有书直接显示书目）；
/// 2. 离线阅读与滚动翻书（进度落库、退出阅读页回到书库）；
/// 3. 离线删除（本地删除成功、tombstone 推送失败静默、无阻塞提示）。
///
/// 服务层离线导入见 offline_import_test.dart；网络恢复补同步与同步报错
/// 静默性专项见 sync_failure_silence_test.dart。
///
/// 前置注入：connectivity 挂载后即上报 none（飞行模式）；同步门面默认
/// 未配置（零网络），配置场景用 FailingBackendAdapter 兜底（零真实网络）。
library;

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/sync/sync_status.dart';
import 'package:sync_reader/features/sync/widgets/sync_status_banner.dart';

import 'offline_env.dart';

void main() {
  setUpAll(() {
    // FakeAsync 环境（isolate 消息不可达）：txt 分页同步化，保证阅读器
    // 打开链路可完成（手法同 test/reader/txt/txt_renderer_widget_test）。
    TxtPaginator.debugSyncPagination = true;
  });

  tearDownAll(() {
    TxtPaginator.debugSyncPagination = false;
  });

  // ── 用例 1：离线冷启动进书库 ────────────────────────────────────────────

  testWidgets('离线冷启动（空书库）：空态引导正常渲染，无报错弹窗', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;

    // 挂载完整应用骨架（触发器宿主 + 全真实页面路由）。
    await pumpOfflineApp(tester, env);
    await tester.pump();
    // 飞行模式：挂载完成后上报无网络（触发器订阅已就绪，转为离线认知）。
    env.connectivity.add(const [ConnectivityResult.none]);
    await tester.pump();
    // 越过启动 2s 全量定时器：未配置同步 → no-op，只报 unconfigured 状态。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    // 书库正常渲染：空态 + 导入引导。
    expect(find.text('SyncReader'), findsOneWidget);
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.textContaining('导入按钮'), findsOneWidget);
    // FR-406 状态横幅允许存在（非阻塞状态条是同步失败的合法表达形式）。
    expect(find.byType(SyncStatusBanner), findsOneWidget);
    expect(find.textContaining('云端同步未配置'), findsOneWidget);
    // 核心断言：全程无阻塞式报错弹窗 / SnackBar。
    expectNoBlockingErrorUi(tester);

    await shutdownOfflineApp(tester, env);
  });

  testWidgets('离线冷启动（已有藏书）：书名直接渲染，无报错弹窗', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    await env.db.booksDao.upsertCompanion(
      bookRow('offlinebook01', title: '飞行模式藏书'),
    );

    await pumpOfflineApp(tester, env);
    await tester.pump();
    env.connectivity.add(const [ConnectivityResult.none]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    // 有书显示书：书名出现在网格卡片。
    expect(find.text('飞行模式藏书'), findsWidgets);
    expect(find.byType(SyncStatusBanner), findsOneWidget);
    expectNoBlockingErrorUi(tester);

    await shutdownOfflineApp(tester, env);
  });

  // ── 用例 2：离线阅读与滚动翻书 ──────────────────────────────────────────

  testWidgets('离线打开 txt 书滚动翻书：进度落库、退出回到书库，全程无报错弹窗', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    const bookId = 'offlinebook02';
    // 导入测试的文件写入手法（真实 IO 在 runAsync）：正文 + 预置封面
    // （封面已存在 → 启动回填跳过，避免无关的真实 IO 干扰）。
    final localPath = (await tester.runAsync(() async {
      final file = File(p.join(env.tmpDir.path, '离线书.txt'));
      await file.writeAsString(longBookText, flush: true);
      final cover = File(env.store.resolveCoverPath(bookId));
      await cover.writeAsBytes(tinyPng, flush: true);
      return file.path;
    }))!;
    await env.db.booksDao.upsertCompanion(
      bookRow(
        bookId,
        title: '离线阅读书',
        localPath: localPath,
        sizeBytes: longBookText.length,
        coverPath: env.store.resolveCoverPath(bookId),
      ),
    );

    // 生命周期置前台（阅读时长计时依赖；手法同 progress_pipeline_test）。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    await pumpOfflineApp(tester, env);
    await tester.pump();
    env.connectivity.add(const [ConnectivityResult.none]);
    await settleReal(tester);
    expect(find.text('离线阅读书'), findsWidgets);

    // 书库 → 详情页。
    await tester.tap(find.text('离线阅读书').first);
    await settleReal(tester);
    expect(find.text('书籍详情'), findsOneWidget);
    expectNoBlockingErrorUi(tester, reason: '（详情页打开时）');

    // 详情页 → 阅读页（默认设置 = 滚动模式）。
    // 详情页含"最近 7 天"块后主按钮落到默认 600px 折叠线下（ListView 惰性
    // 构建）：临时加高视口完成点击，进入阅读器后恢复原视口（阅读分页/滚动
    // 断言仍按默认视口行为验证）。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    await tester.pump(); // 新视口生效重建 ListView（折叠下按钮进入构建范围）。
    await tester.tap(find.text('开始阅读'));
    await pumpUntilReaderReady(tester);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();
    expect(find.text('离线阅读书'), findsOneWidget); // AppBar 书名
    expect(find.textContaining('第一章 开端'), findsWidgets); // 正文渲染
    expectNoBlockingErrorUi(tester, reason: '（阅读页打开时）');

    // 滚动翻书（连续滚动两屏）。
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    // 渲染器节流 500ms → 宿主防抖 3s → 进度落库。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 3));
    expectNoBlockingErrorUi(tester, reason: '（翻书后）');
    final progress = await env.db.progressDao.getByBookId(bookId);
    expect(progress, isNotNull, reason: '离线翻书进度必须正常落库');
    expect(progress!.percent, greaterThan(0));
    expect(progress.percent, lessThanOrEqualTo(1));
    expect(progress.dirty, isTrue, reason: '离线期间进度应为待同步（dirty）');

    // 退出阅读页（AppBar 返回；PopScope 先落库再退出）。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await settleReal(tester, windows: 4);
    expect(find.text('书籍详情'), findsOneWidget, reason: '已退出阅读页回详情');
    expectNoBlockingErrorUi(tester, reason: '（退出阅读页后）');

    // 退出立即结算的进度仍在（退出不丢进度）。
    final afterExit = await env.db.progressDao.getByBookId(bookId);
    expect(afterExit, isNotNull);
    expect(afterExit!.percent, greaterThan(0));

    // 返回书库：书目仍在，卡片进度徽标可见（本地优先的端到端印证）。
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('离线阅读书'), findsWidgets);
    expect(find.textContaining('%'), findsWidgets);
    expectNoBlockingErrorUi(tester, reason: '（回到书库后）');

    await shutdownOfflineApp(tester, env);
  });

  // ── 用例 4：离线删除 ────────────────────────────────────────────────────

  testWidgets('离线删除：本地删除成功 + tombstone 推送失败静默，无报错弹窗', (tester) async {
    final env = (await tester.runAsync(OfflineEnv.create))!;
    await env.configureCredentials();
    // 配置齐全 + 必败适配器：引擎可构建，云端操作全部失败（tombstone 推送
    // 必然失败）——验证"失败静默重试语义"下 UI 无阻塞提示。
    final failing = FailingBackendAdapter(const NetworkUnreachable('网络不可达'));
    const bookId = 'offlinebook03';
    // 正文写入书库布局内（books/{bookId}/source.txt）——删除的游离语义
    // （moveToOrphans 整目录改名）依赖该布局。
    final localPath = (await tester.runAsync(() async {
      final path = env.store.resolveBookPath(bookId, 'txt');
      final file = File(path);
      await file.create(recursive: true);
      await file.writeAsString('正文内容', flush: true);
      final cover = File(env.store.resolveCoverPath(bookId));
      await cover.writeAsBytes(tinyPng, flush: true);
      return path;
    }))!;
    await env.db.booksDao.upsertCompanion(
      bookRow(
        bookId,
        title: '离线待删书',
        localPath: localPath,
        coverPath: env.store.resolveCoverPath(bookId),
      ),
    );

    await pumpOfflineApp(
      tester,
      env,
      adapterProvider: FixedAdapterProvider(failing),
    );
    await tester.pump();
    env.connectivity.add(const [ConnectivityResult.none]);
    await settleReal(tester);

    // 书库 → 详情页 → 删除。
    await tester.tap(find.text('离线待删书').first);
    await settleReal(tester);
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    // 删除确认框是用户显式操作（允许存在），确认后不得再有任何报错弹窗。
    expect(find.text('删除《离线待删书》？'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await settleReal(tester);

    // 已返回书库，书目消失（空态）。
    expect(find.text('离线待删书'), findsNothing);
    expect(find.text('书库为空'), findsOneWidget);
    expectNoBlockingErrorUi(tester, reason: '（删除完成后——tombstone 推送失败必须静默）');

    // 本地删除真实生效：书目行删除 + 回收区账本 + 正文移游离区。
    await tester.runAsync(() async {
      expect(await env.db.booksDao.getById(bookId), isNull);
      final ledger = await env.db.select(env.db.deletedBooks).get();
      expect(ledger, hasLength(1));
      expect(ledger.single.bookId, bookId);
      expect(
        ledger.single.pushed,
        isFalse,
        reason: '飞行模式下 tombstone 推送失败，账本保留待网络恢复补推',
      );
      expect(File(localPath).existsSync(), isFalse, reason: '正文移入游离区');
      expect(await env.store.listOrphans(), hasLength(1));
    });
    // 删除推送确实尝试过并失败（静默 ≠ 未发生）。
    expect(failing.connectCalls, greaterThanOrEqualTo(1));
    expect(failing.getMetaCalls, greaterThanOrEqualTo(1));
    // 失败未进全局状态（deleteBook 语义 = 完全静默，FR-408）。
    final memory = ProviderScope.containerOf(
      tester.element(find.byType(SyncStatusBanner)),
    ).read(syncMemoryStatusProvider);
    expect(memory.id, isNot(SyncStateId.failed));
    expect(memory.failureText, isNull);

    await shutdownOfflineApp(tester, env);
  });
}

/// 等待阅读页就绪（真实 IO 链在 runAsync 窗口内逐环完成；有界轮询防挂起）。
Future<void> pumpUntilReaderReady(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    final ready =
        find.byType(ListView).evaluate().isNotEmpty &&
        find.textContaining('第一章 开端').evaluate().isNotEmpty;
    if (ready) break;
  }
  await tester.pumpAndSettle();
}
