/// 书库侧 Riverpod 状态（FR-101/104/105/106）。
///
/// 约定：
/// - 书籍列表直接消费 `booksDao.watchBooks`（drift watch，UI 自动刷新）；
/// - `library_view` 视图模式持久化到 reader_settings 表（经
///   ReaderSettingsDao 直接读写独立键，不碰 ReaderSettings JSON）；
/// - 全部 provider 定义在本文件（providers.dart 归基建所有，不改动）。
library;

import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/book_groups_dao.dart';
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

/// 分组 DAO（FR-107 本地分类）：仅书库侧使用，groupsProvider / 分组管理
/// 对话框共用（app/providers.dart 归基建所有，不在其上追加）。
final bookGroupsDaoProvider = Provider<BookGroupsDao>(
  (ref) => ref.watch(databaseProvider).bookGroupsDao,
);

/// 全部分组流（FR-107）：与书列表同为 drift watch，建/改/删组后 chip 栏与
/// 管理对话框自动刷新。查询与 `BookGroupsDao.allGroups` 同序（sortOrder、
/// createdAt 升序）；DAO 只提供一次性 Future，故 watch 查询在此装配。
final groupsProvider = StreamProvider<List<BookGroup>>((ref) {
  final db = ref.watch(databaseProvider);
  final query = db.select(db.bookGroups)
    ..orderBy([
      (g) => OrderingTerm.asc(g.sortOrder),
      (g) => OrderingTerm.asc(g.createdAt),
    ]);
  return query.watch();
});

/// 书库分组过滤状态（FR-107）：all = 不过滤；ungrouped = 只看未分组；
/// selected(id) = 只看该分组。三种视图互斥（ungrouped 与 group(id) 映射到
/// `watchBooks` 的两个互斥参数，ungroupedOnly 优先）。
sealed class LibraryGroupFilter {
  const LibraryGroupFilter();

  /// 全部（不过滤）。
  static const LibraryGroupFilter all = _AllGroupFilter();

  /// 仅未分组。
  static const LibraryGroupFilter ungrouped = _UngroupedGroupFilter();

  /// 映射到 `BooksDao.watchBooks` 的分组过滤参数。
  ({String? groupFilterId, bool ungroupedOnly}) get queryArgs =>
      switch (this) {
        _AllGroupFilter() => (groupFilterId: null, ungroupedOnly: false),
        _UngroupedGroupFilter() => (groupFilterId: null, ungroupedOnly: true),
        final GroupFilterSelected s => (
          groupFilterId: s.groupId,
          ungroupedOnly: false,
        ),
      };
}

/// 选中某个分组（按 groupId 判等）。
final class GroupFilterSelected extends LibraryGroupFilter {
  const GroupFilterSelected(this.groupId);

  final String groupId;

  @override
  bool operator ==(Object other) =>
      other is GroupFilterSelected && other.groupId == groupId;

  @override
  int get hashCode => Object.hash(GroupFilterSelected, groupId);
}

final class _AllGroupFilter extends LibraryGroupFilter {
  const _AllGroupFilter();
}

final class _UngroupedGroupFilter extends LibraryGroupFilter {
  const _UngroupedGroupFilter();
}

/// 书库分组过滤状态：默认「全部」；仅会话内记忆，不持久化。
final libraryGroupFilterProvider =
    NotifierProvider<LibraryGroupFilterNotifier, LibraryGroupFilter>(
      LibraryGroupFilterNotifier.new,
    );

final class LibraryGroupFilterNotifier extends Notifier<LibraryGroupFilter> {
  @override
  LibraryGroupFilter build() => LibraryGroupFilter.all;

  void set(LibraryGroupFilter filter) => state = filter;
}

/// 书库列表流：排序 + 搜索 + 分组过滤即时生效（drift watch；过滤条件
/// 变化时重查由 watch 模式自动完成）。
final booksStreamProvider = StreamProvider<List<Book>>((ref) {
  final dao = ref.watch(booksDaoProvider);
  final args = ref.watch(libraryGroupFilterProvider).queryArgs;
  return dao.watchBooks(
    sort: ref.watch(bookSortProvider),
    query: ref.watch(libraryQueryProvider),
    groupFilterId: args.groupFilterId,
    ungroupedOnly: args.ungroupedOnly,
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
