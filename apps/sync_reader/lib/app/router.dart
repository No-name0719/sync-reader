import 'package:go_router/go_router.dart';

import '../features/library/book_detail_page.dart';
import '../features/library/library_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell/app_shell.dart';
import '../features/sync/pages/jianguoyun_guide_page.dart';
import '../features/sync/pages/sync_settings_page.dart';

/// 路由表（docs/03 §2 + docs/10 §4.1 A1）：
/// - `/`                  书库首页（书库代理重写，shell 内）
/// - `/book/:bookId`      书籍详情（书库代理重写，shell 内）
/// - `/reader/:bookId`    阅读页（集成代理填充进度管线；**不包外壳**，全屏沉浸）
/// - `/sync/settings`     同步设置（M2 同步代理，shell 内）
/// - `/sync/guide`        坚果云配置向导（M2 同步代理，shell 内）
/// - `/settings`          应用设置（v1.1 新增 A15，shell 内）
///
/// 外壳内页面共用一个 [ShellRoute]（AppShell 提供侧栏/底栏，页面自带
/// Scaffold/AppBar）。所有既有路径保持不变（页面内 `context.go('/')`、
/// `/reader/:id` 等硬编码跳转不受影响）。
final router = GoRouter(
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.matchedLocation, child: child),
      routes: [
        GoRoute(path: '/', builder: (context, state) => const LibraryPage()),
        GoRoute(
          path: '/book/:bookId',
          builder: (context, state) =>
              BookDetailPage(bookId: state.pathParameters['bookId']!),
        ),
        GoRoute(
          path: '/sync/settings',
          builder: (context, state) => const SyncSettingsPage(),
        ),
        GoRoute(
          path: '/sync/guide',
          builder: (context, state) => const JianguoYunGuidePage(),
        ),
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
      ],
    ),
    // 阅读器留在 shell 外：全屏沉浸（docs/10 §4.1）。
    GoRoute(
      path: '/reader/:bookId',
      builder: (context, state) =>
          ReaderPage(bookId: state.pathParameters['bookId']!),
    ),
  ],
);
