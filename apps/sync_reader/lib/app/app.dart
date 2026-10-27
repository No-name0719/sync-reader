import 'package:flutter/material.dart';

import 'router.dart';

/// 应用根组件：Material 3 主题（浅/深跟随系统，FR-603）+ 声明式路由
/// （docs/02 §D7：Riverpod + go_router）。ProviderScope 由 main.dart 提供。
class SyncReaderApp extends StatelessWidget {
  const SyncReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SyncReader',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      routerConfig: router,
    );
  }
}
