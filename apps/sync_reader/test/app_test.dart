import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/app.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/app/router.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/shell/app_shell.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  testWidgets('应用根组件：书库首页在应用外壳内渲染', (tester) async {
    // 1200×800 → ≥1180：232px 宽侧栏 + 品牌区。
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: SyncReaderApp()));
    await tester.pumpAndSettle();
    // 外壳品牌区出现产品名（v1.1 A1：应用名从书库 AppBar 移到外壳品牌区）。
    expect(find.text('SyncReader'), findsOneWidget);
    // 书库内容照常渲染（空书库状态）。
    expect(find.text('书库为空'), findsOneWidget);
    // 外壳导航三项可见（「书库」出现两次：外壳导航项 + 书库页 AppBar 标题，
    // v1.1 A4 书库页新增常驻标题）。
    expect(find.text('书库'), findsNWidgets(2));
    expect(find.text('同步'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // 既有路径保持可用：路由到 /settings 渲染设置页（仍在壳内）。
    router.go('/settings');
    await tester.pumpAndSettle();
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('设置'), findsWidgets);
  });

  testWidgets('批 7 路由：/tools/batch-import 与 /sync/cloudlib 可达；'
      '同步卡「进入管理」落到云端书库页；外壳高亮按前缀归组', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    // 真实 IO（临时目录）必须在 runAsync 窗口内完成，否则 future 在
    // fakeAsync 区永不交付（同 batch_import_page_test 的教训）。
    final tmpDir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('app_routes_test'),
    );
    final tmp = tmpDir!;
    // 收尾与 cloud_library_page_test 冒烟用例同款：测试体末尾卸载树 →
    // LIFO 先 dispose 容器（取消 drift 流订阅）→ pump 排空定时器 →
    // 真实区关库。顺序颠倒会残留 markAsClosed 的 fake timer。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(() async {
        await db.close();
        if (tmp.existsSync()) tmp.delete(recursive: true);
      });
    });
    final container = ProviderContainer(
      overrides: [
        // 内存库 + 内存凭据 + 内存适配器：批量导入首屏与云端书库页
        // （未配置引导态）都不触平台通道。
        databaseProvider.overrideWithValue(db),
        bookFileStoreProvider.overrideWith((ref) async => BookFileStore(tmp)),
        secureCredentialStoreProvider.overrideWithValue(
          InMemoryCredentialStore(),
        ),
        syncAdapterProvider.overrideWithValue(
          const InMemorySyncAdapterProvider(),
        ),
      ],
    );
    addTearDown(container.dispose);

    // 直挂 MaterialApp.router（真 router + 真外壳路由）：路由可达性测试
    // 不需要 SyncReaderApp 的触发器宿主（其 15min 周期定时器在
    // UncontrolledProviderScope 下无法可靠随树卸载取消，会残留 fake timer）。
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // /tools/batch-import：批量导入首屏（选文件夹），壳内渲染。
    router.go('/tools/batch-import');
    await tester.pumpAndSettle();
    expect(find.text('批量导入（文件夹）'), findsOneWidget);
    expect(find.text('选择文件夹'), findsOneWidget);
    // 前缀匹配：/tools/* 归书库组（未匹配回落书库）。
    expect(
      ShellDestination.of('/tools/batch-import'),
      ShellDestination.library,
    );

    // /sync/settings 的「云端书库」卡「进入管理」→ /sync/cloudlib（批 6 入口接线）。
    router.go('/sync/settings');
    await tester.pumpAndSettle();
    // 卡片在页面下方：先滚入可视区再点。
    await tester.ensureVisible(find.byKey(const ValueKey('cloudlib-entry')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloudlib-entry')));
    await tester.pumpAndSettle();
    expect(find.text('云端书库'), findsOneWidget);
    // 未配置同步 → 引导态（§4.8）。
    expect(find.text('尚未配置同步'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    // 前缀匹配：/sync/* 归同步组（含 cloudlib 子路径）。
    expect(ShellDestination.of('/sync/cloudlib'), ShellDestination.sync);

    // 测试体末尾卸载树：container dispose 的 drift 收尾定时器由后续
    // teardown 的 pump 排空。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
