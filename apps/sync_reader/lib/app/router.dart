import 'package:go_router/go_router.dart';

import '../features/library/book_detail_page.dart';
import '../features/library/import/batch_import_page.dart';
import '../features/library/library_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell/app_shell.dart';
import '../features/sync/pages/cloud_library_page.dart';
import '../features/sync/pages/jianguoyun_guide_page.dart';
import '../features/sync/pages/sync_settings_page.dart';

/// 路由表（docs/03 §2 + docs/10 §4.1 A1）：
/// - `/`                  书库首页（书库代理重写，shell 内）
/// - `/book/:bookId`      书籍详情（书库代理重写，shell 内）
/// - `/reader/:bookId`    阅读页（集成代理填充进度管线；**不包外壳**，全屏沉浸）
/// - `/sync/settings`     同步设置（M2 同步代理，shell 内）
/// - `/sync/guide`        坚果云配置向导（M2 同步代理，shell 内）
/// - `/sync/cloudlib`     云端书库管理（v1.1 A16 新增，shell 内，归同步组）
/// - `/tools/batch-import` 批量导入（v1.1 A16：入口移到书库顶栏分裂按钮，shell 内，归书库组）
/// - `/settings`          应用设置（v1.1 新增 A15，shell 内）
///
/// 外壳内页面共用一个 [ShellRoute]（AppShell 提供侧栏/底栏，页面自带
/// Scaffold/AppBar）。所有既有路径保持不变（页面内 `context.go('/')`、
/// `/reader/:id` 等硬编码跳转不受影响）。
///
/// 外壳导航不需要改（[ShellDestination.of] 的前缀匹配已覆盖：
/// `/sync/*` → 同步组、`/tools/*` → 书库组）。
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
        // 云端书库管理（A16 / §4.8）：同步卡入口进入，导航高亮归同步组。
        GoRoute(
          path: '/sync/cloudlib',
          builder: (context, state) => const CloudLibraryPage(),
        ),
        // 批量导入（A16）：书库分裂按钮「批量导入（文件夹）」进入，归书库组。
        GoRoute(
          path: '/tools/batch-import',
          builder: (context, state) => const BatchImportPage(),
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
