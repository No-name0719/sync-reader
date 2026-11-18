import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/onboarding.dart';
import 'app/providers.dart';
import 'app/window.dart';
import 'core/startup_timer.dart';
import 'data/db/app_database.dart';

Future<void> main() async {
  // 启动打点起点（NFR-05：冷启动到书库可交互）。
  startupTimer.mark(StartupTimer.kProcessStart);
  WidgetsFlutterBinding.ensureInitialized();
  // Windows：恢复窗口尺寸/位置（其他平台为空操作）。
  await initDesktopWindow();

  // 首启判定（docs/10 §4.9）：读 `app.onboarding.done` 标志，决定首屏是
  // 书库还是首启引导页。
  //
  // 放在 runApp **之前**：路由 redirect 第一次求值时状态已是终态，
  // 首启页与书库之间不会闪一帧（否则新用户会先看到书库再被弹走）。
  // 数据库在此处建连并复用（同一实例注入 provider，不重复开库）。
  //
  // 读表失败由闸门内部兜底为「已完成」——首启页绝不阻断启动。
  final database = AppDatabase();
  await onboardingGate.load(database.appSettingsDao);

  runApp(
    ProviderScope(
      // 数据库实例已在上面建好并读过一次标志，这里复用同一个（避免二次开库）。
      // 代价：provider 被 override 后不再随容器 dispose 关闭数据库；
      // 应用以进程退出收尾，SQLite 句柄随进程释放。
      overrides: [databaseProvider.overrideWithValue(database)],
      child: const SyncReaderApp(),
    ),
  );
}
