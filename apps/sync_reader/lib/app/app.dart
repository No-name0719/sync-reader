import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/design_tokens.dart';
import '../core/startup_timer.dart';
import '../features/library/import/cover_generator.dart';
import '../features/sync/sync_facade.dart';
import 'app_preferences.dart';
import 'router.dart';

/// 应用根组件：设计令牌主题（浅/深跟随系统，FR-603）+ 声明式路由
/// （docs/02 §D7：Riverpod + go_router）。ProviderScope 由 main.dart 提供。
///
/// 主题不再用 `colorSchemeSeed`（塑料感来源，docs/10 §1.2 T2），
/// 改为 `AppTheme.light/dark` 显式填色（docs/10 §3.1）。
/// accent / 外观模式的持久化状态在 `app_preferences.dart`（第 2 批接入
/// app_settings 表），此处只 watch。
///
/// 根部依次挂两层宿主：
/// - [AppPreferencesHydrator]（app_preferences.dart）：启动时异步读回
///   accent / 外观模式（读表失败回落默认，不阻塞首帧）；
/// - [_SyncTriggerHost]：M2 同步触发器（docs/04 §3 启动 2s 全量、
///   回前台、定时器、网络恢复）随容器挂载/卸载，测试环境 teardown 时
///   全部定时器随 provider dispose 取消，不产生悬挂 Timer。
class SyncReaderApp extends ConsumerWidget {
  const SyncReaderApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(appAccentProvider);
    final themeMode = ref.watch(appThemeModeProvider);
    return AppPreferencesHydrator(
      child: SyncTriggerHost(
        child: MaterialApp.router(
          title: 'SyncReader',
          theme: AppTheme.light(accent),
          darkTheme: AppTheme.dark(accent),
          themeMode: themeMode,
          routerConfig: router,
          scrollBehavior: const AppScrollBehavior(),
        ),
      ),
    );
  }
}

/// 应用级滚动行为（E5-2）：在 Flutter 默认的「触控类设备」拖拽集合上
/// **追加鼠标**，使桌面端的滚动容器（如 Aa 排版面板）可以用鼠标按住拖动
/// 滚动，而不必依赖触控板/滚轮。
///
/// 说明与影响范围：
/// - 默认集合（touch / stylus / invertedStylus / trackpad / unknown）**保留**，
///   只做追加，不替换；
/// - 这是**全应用生效**的改动：所有继承 [ScrollConfiguration] 的滚动容器
///   （书库列表、目录抽屉、排版面板、阅读页正文滚动区等）在桌面端都可用
///   鼠标拖动滚动；
/// - Flutter 官方提示：开启鼠标拖拽后，滚动容器内的文本选择会变难
///   （鼠标拖动可能被识别为滚动手势）。本应用的阅读正文为只读渲染、
///   不提供文本选择交互，故取此取舍。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}

/// 同步触发器宿主：首帧挂载 [SyncTriggers]，卸载时 detach（清理定时器）。
class SyncTriggerHost extends ConsumerStatefulWidget {
  const SyncTriggerHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SyncTriggerHost> createState() => _SyncTriggerHostState();
}

final class _SyncTriggerHostState extends ConsumerState<SyncTriggerHost> {
  @override
  void initState() {
    super.initState();
    // 触发器构建失败（如平台层缺失）不阻塞应用启动。
    try {
      ref.read(syncTriggersProvider).attach();
    } catch (_) {
      // 静默：同步是旁路，任何失败不影响本地阅读（CLAUDE.md §4.1）。
    }
    // 存量封面回填（一次性）：修复前已下载的书（coverPath 为空）重启后
    // 补出真实封面。fire-and-forget；provider/数据层不可用时静默失败。
    unawaited(
      ref.read(coverGeneratorProvider).backfillMissing().catchError((_) {}),
    );
    // 首帧打点（NFR-05 口径 = 书库可交互）+ 汇总输出。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      startupTimer.mark(StartupTimer.kFirstFrame);
      startupTimer.report();
    });
  }

  @override
  void dispose() {
    try {
      ref.read(syncTriggersProvider).detach();
    } catch (_) {
      // 容器可能已先行销毁。
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
