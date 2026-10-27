/// 书库侧 Riverpod 状态（FR-101/104/105/106）。
///
/// 约定：
/// - 书籍列表直接消费 `booksDao.watchBooks`（drift watch，UI 自动刷新）；
/// - `library_view` 视图模式持久化到 reader_settings 表（经
///   ReaderSettingsDao 直接读写独立键，不碰 ReaderSettings JSON）；
/// - 全部 provider 定义在本文件（providers.dart 归基建所有，不改动）。
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/books_dao.dart';
import '../reader/contract/book_file.dart';
import 'import/book_import_service.dart';

/// 书库视图模式（FR-105）。
enum LibraryViewMode { grid, list }

/// 书库视图模式状态：默认网格，启动时异步从 reader_settings 恢复；
/// 切换即落库（key = `library_view`）。
final libraryViewModeProvider =
    NotifierProvider<LibraryViewModeNotifier, LibraryViewMode>(
      LibraryViewModeNotifier.new,
    );

final class LibraryViewModeNotifier extends Notifier<LibraryViewMode> {
  /// reader_settings 表中的存储键。
  static const storageKey = 'library_view';

  @override
  LibraryViewMode build() {
    _restore();
    return LibraryViewMode.grid;
  }

  Future<void> _restore() async {
    String? raw;
    try {
      raw = await ref.read(readerSettingsDaoProvider).getValue(storageKey);
    } catch (_) {
      // 数据层暂不可用（如无平台通道的测试环境）：保持默认网格。
      return;
    }
    if (!ref.mounted || raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      final name = decoded is String ? decoded : null;
      final mode = LibraryViewMode.values
          .where((m) => m.name == name)
          .firstOrNull;
      if (mode != null) state = mode;
    } on FormatException {
      // 值损坏则保持默认，不阻塞书库。
    }
  }

  /// 切换视图模式并持久化。
  Future<void> setMode(LibraryViewMode mode) async {
    state = mode;
    await ref
        .read(readerSettingsDaoProvider)
        .setValue(storageKey, jsonEncode(mode.name));
  }
}

/// 书库排序状态（FR-105）：默认最近阅读；仅会话内记忆，不持久化。
final bookSortProvider = NotifierProvider<BookSortNotifier, BookSort>(
  BookSortNotifier.new,
);

final class BookSortNotifier extends Notifier<BookSort> {
  @override
  BookSort build() => BookSort.lastRead;

  void set(BookSort sort) => state = sort;
}

/// 书库搜索词（FR-106）：UI 侧防抖 300ms 后写入，直接透传给 watchBooks。
final libraryQueryProvider = NotifierProvider<LibraryQueryNotifier, String>(
  LibraryQueryNotifier.new,
);

final class LibraryQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

/// 书库列表流：排序 + 搜索即时生效（drift watch）。
final booksStreamProvider = StreamProvider<List<Book>>((ref) {
  final dao = ref.watch(booksDaoProvider);
  return dao.watchBooks(
    sort: ref.watch(bookSortProvider),
    query: ref.watch(libraryQueryProvider),
  );
});

/// 全部阅读进度：bookId → 进度行（网格/列表的进度与时长徽标用）。
final progressMapProvider = StreamProvider<Map<String, BookProgress>>((ref) {
  final db = ref.watch(databaseProvider);
  return db
      .select(db.progress)
      .watch()
      .map((rows) => {for (final row in rows) row.bookId: row});
});

/// 单本书进度流（详情页实时展示）。
final bookProgressProvider = StreamProvider.family<BookProgress?, String>((
  ref,
  bookId,
) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.progress)
    ..where((row) => row.bookId.equals(bookId));
  return query.watchSingleOrNull();
});

/// 单本书详情（getById 一次性读取；删除后导航离开，无需 watch）。
final bookDetailProvider = FutureProvider.family<Book?, String>((ref, bookId) {
  return ref.watch(booksDaoProvider).getById(bookId);
});

/// 目录章节数（FR-108 书库侧）：按已存 localPath 重新解析元数据取 toc 长度。
///
/// 返回 null 表示无法给出（占位书/无 handler/文件丢失）；解析由 handler
/// 基类保证不抛出。详情页展示"共 N 章"即可，TOC 抽屉由阅读器负责。
final tocCountProvider = FutureProvider.family<int?, String>((
  ref,
  bookId,
) async {
  final book = await ref.watch(bookDetailProvider(bookId).future);
  final path = book?.localPath;
  if (book == null || path == null || path.isEmpty) return null;
  final handler = ref.watch(formatRegistryProvider).byFormatId(book.format);
  if (handler == null) return null;
  try {
    final file = await BookFile.fromPath(path);
    final parsed = await handler.parseMetadata(file);
    return parsed.toc.length;
  } catch (_) {
    // 正文文件已丢失（如已被移入游离区）→ 无法统计。
    return null;
  }
});

/// 导入服务（依赖注入见 [BookImportService]）。
final bookImportServiceProvider = Provider<BookImportService>((ref) {
  return BookImportService(
    booksDao: ref.watch(booksDaoProvider),
    registry: ref.watch(formatRegistryProvider),
    fileStore: ref.watch(bookFileStoreProvider.future),
  );
});
