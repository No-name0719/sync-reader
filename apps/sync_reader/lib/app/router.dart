import 'package:go_router/go_router.dart';

import '../features/library/book_detail_page.dart';
import '../features/library/import/batch_import_page.dart';
import '../features/library/library_page.dart';
import '../features/onboarding/onboarding_page.dart';
import '../features/reader/reader_page.dart';
import '../features/settings/settings_page.dart';
import '../features/shell/app_shell.dart';
import '../features/sync/pages/cloud_library_page.dart';
import '../features/sync/pages/jianguoyun_guide_page.dart';
import '../features/sync/pages/sync_settings_page.dart';
import 'onboarding.dart';

/// 路由表（docs/03 §2 + docs/10 §4.1 A1）：
/// - `/`                  书库首页（书库代理重写，shell 内）
/// - `/book/:bookId`      书籍详情（书库代理重写，shell 内）
/// - `/reader/:bookId`    阅读页（集成代理填充进度管线；**不包外壳**，全屏沉浸）
/// - `/sync/settings`     同步设置（M2 同步代理，shell 内）
/// - `/sync/guide`        坚果云配置向导（M2 同步代理，shell 内）
/// - `/sync/cloudlib`     云端书库管理（v1.1 A16 新增，shell 内，归同步组）
/// - `/tools/batch-import` 批量导入（v1.1 A16：入口移到书库顶栏分裂按钮，shell 内，归书库组）
/// - `/settings`          应用设置（v1.1 新增 A15，shell 内）
/// - `/onboarding`        首启引导页（首次启动的坚果云配置入口，可跳过）
/// - `/onboarding/guide`  首启专用的四步向导（全屏，不套外壳）
///
/// 外壳内页面共用一个 [ShellRoute]（AppShell 提供侧栏/底栏，页面自带
/// Scaffold/AppBar）。所有既有路径保持不变（页面内 `context.go('/')`、
/// `/reader/:id` 等硬编码跳转不受影响）。
///
/// 外壳导航不需要改（[ShellDestination.of] 的前缀匹配已覆盖：
/// `/sync/*` → 同步组、`/tools/*` → 书库组）。
///
/// 首启拦截由 [redirect] 承担（docs/10 §4.9）：闸门状态在首帧之前已判定完
/// （见 main.dart），所以第一次求值就能给出终局，不必「先显示书库再跳走」：
/// - 未完成首启 → 落点书库改为 `/onboarding`；
/// - 首启已完成 → 从首启页/首启向导回书库。
/// 判定未出结果时（测试环境）一律不拦路。
final router = GoRouter(
  initialLocation: '/',
  redirect: (context, state) {
    final location = state.matchedLocation;
    switch (onboardingGate.status) {
      case OnboardingStatus.unknown:
        return null;
      case OnboardingStatus.pending:
        // 只拦启动落点（书库）：进向导后放行，避免把用户拽回首启页。
        return location == '/' ? '/onboarding' : null;
      case OnboardingStatus.completed:
        return location == '/onboarding' || location == '/onboarding/guide'
            ? '/'
            : null;
    }
  },
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
    // 首启引导页留在 shell 外：首屏还没有导航可言，全屏更干净。
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingPage(),
    ),
    // 首启专用的四步向导：与 `/sync/guide` 同一个控件，只是不套外壳，
    // 保证首启全程（全屏首启页 → 全屏向导）不突然冒出侧栏。
    GoRoute(
      path: '/onboarding/guide',
      builder: (context, state) => const JianguoYunGuidePage(),
    ),
  ],
);
