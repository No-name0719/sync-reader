import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Windows：恢复窗口尺寸/位置（其他平台为空操作）。
  await initDesktopWindow();
  runApp(const ProviderScope(child: SyncReaderApp()));
}
