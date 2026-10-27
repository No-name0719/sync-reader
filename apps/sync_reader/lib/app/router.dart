import 'package:go_router/go_router.dart';

import '../features/library/book_detail_page.dart';
import '../features/library/library_page.dart';
import '../features/reader/reader_page.dart';
import '../features/sync/pages/jianguoyun_guide_page.dart';
import '../features/sync/pages/sync_settings_page.dart';

/// 路由表（docs/03 §2）：
/// - `/`                书库首页（书库代理重写）
/// - `/book/:bookId`    书籍详情（书库代理重写）
/// - `/reader/:bookId`  阅读页（集成代理填充进度管线）
/// - `/sync/settings`   同步设置（M2 同步代理）
/// - `/sync/guide`      坚果云配置向导（M2 同步代理）
final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const LibraryPage()),
    GoRoute(
      path: '/book/:bookId',
      builder: (context, state) =>
          BookDetailPage(bookId: state.pathParameters['bookId']!),
    ),
    GoRoute(
      path: '/reader/:bookId',
      builder: (context, state) =>
          ReaderPage(bookId: state.pathParameters['bookId']!),
    ),
    GoRoute(
      path: '/sync/settings',
      builder: (context, state) => const SyncSettingsPage(),
    ),
    GoRoute(
      path: '/sync/guide',
      builder: (context, state) => const JianguoYunGuidePage(),
    ),
  ],
);
