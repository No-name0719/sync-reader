import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/window.dart';
import 'core/startup_timer.dart';

Future<void> main() async {
  // 启动打点起点（NFR-05：冷启动到书库可交互）。
  startupTimer.mark(StartupTimer.kProcessStart);
  WidgetsFlutterBinding.ensureInitialized();
  // Windows：恢复窗口尺寸/位置（其他平台为空操作）。
  await initDesktopWindow();
  runApp(const ProviderScope(child: SyncReaderApp()));
}
