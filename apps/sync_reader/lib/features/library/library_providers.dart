/// 书库侧 Riverpod 状态（FR-101/104/105/106；v1.1 A4/A18 两层筛选）。
///
/// 约定：
/// - 书籍列表直接消费 `booksDao.watchBooks`（drift watch，UI 自动刷新）；
///   排序与搜索走 SQL，状态/分组两层筛选在内存取交集（2000 本量级内存
///   过滤无压力，FR-106 基准只测 SQL 搜索）；
/// - `library_view` 视图模式持久化到 reader_settings 表（经
///   ReaderSettingsDao 直接读写独立键，不碰 ReaderSettings JSON）；
/// - 全部 provider 定义在本文件（providers.dart 归基建所有，不改动）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/book_groups_dao.dart';
import '../../data/db/daos/books_dao.dart';
import '../../data/db/daos/local_only_books_dao.dart';
import '../reader/contract/book_file.dart';
import '../sync/sync_facade.dart' show driftLocalLibraryProvider;
import '../sync/sync_status.dart' show syncMemoryStatusProvider;
import 'import/book_import_service.dart';
import 'library_filters.dart';

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

/// 第一层筛选（v1.1 A4，Q20）：状态 chip 互斥单选，默认「全部」；
/// 仅会话内记忆，不持久化。
final libraryStatusFilterProvider =
    NotifierProvider<LibraryStatusFilterNotifier, LibraryStatusFilter>(
      LibraryStatusFilterNotifier.new,
    );

final class LibraryStatusFilterNotifier extends Notifier<LibraryStatusFilter> {
  @override
  LibraryStatusFilter build() => LibraryStatusFilter.all;

  void set(LibraryStatusFilter filter) => state = filter;
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

/// 书库分组过滤状态（第二层筛选，A4/A18）：all = 不过滤；ungrouped = 只看
/// 未分组；selected(id) = 只看该分组。旧版「未下载」维度已移除（Q12：
/// 在读/未下载交给状态层与排序表达），分组过滤改在内存与状态层取交集。
sealed class LibraryGroupFilter {
  const LibraryGroupFilter();

  /// 全部（不过滤）。
  static const LibraryGroupFilter all = _AllGroupFilter();

  /// 仅未分组。
  static const LibraryGroupFilter ungrouped = _UngroupedGroupFilter();
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

/// 分组筛选命中判定（Book.groupId 为本地列）。
bool groupFilterMatches(LibraryGroupFilter filter, Book book) =>
    switch (filter) {
      _AllGroupFilter() => true,
      _UngroupedGroupFilter() => book.groupId == null,
      GroupFilterSelected(:final groupId) => book.groupId == groupId,
    };

/// 分组筛选的展示名（分组下拉按钮与菜单项共用）。
String groupFilterLabel(LibraryGroupFilter filter, List<BookGroup> groups) =>
    switch (filter) {
      _AllGroupFilter() => '全部分组',
      _UngroupedGroupFilter() => '未分组',
      GroupFilterSelected(:final groupId) =>
        groups
                .where((g) => g.groupId == groupId)
                .map((g) => g.name)
                .firstOrNull ??
            '全部分组',
    };

/// 书库列表流：排序 + 搜索即时生效（drift watch）。分组/状态两层筛选在
/// [filteredLibraryProvider] 内存取交集，不在 SQL 叠加。
final booksStreamProvider = StreamProvider<List<Book>>((ref) {
  final dao = ref.watch(booksDaoProvider);
  return dao.watchBooks(
    sort: ref.watch(bookSortProvider),
    query: ref.watch(libraryQueryProvider),
  );
});

/// 「仅本地」bookId 集合流（docs/10 §4.7c：状态桶判定与卡片角标用）。
final localOnlyIdsProvider = StreamProvider<Set<String>>((ref) {
  return ref.watch(localOnlyBooksDaoProvider).watchLocalOnlyBookIds();
});

/// 「云端有」近似集合流：`sync_state` 有行（baseRev 存在）的 bookId。
/// 只读 watch（A18 数据源，见 BooksDao.watchSyncStateBookIds）。
final cloudBaseIdsProvider = StreamProvider<Set<String>>((ref) {
  return ref.watch(booksDaoProvider).watchSyncStateBookIds();
});

/// 本轮同步判定「云端缺失」的书（DriftLocalLibrary.cloudMissingMarks）。
///
/// 内存 Set 本身非响应式：以 [syncMemoryStatusProvider]（facade 每轮同步
/// 后必更新）为触发源重读一次，简单保证每轮同步后书库筛选刷新。
final cloudMissingMarksProvider = Provider<Set<String>>((ref) {
  ref.watch(syncMemoryStatusProvider);
  return ref.watch(driftLocalLibraryProvider).cloudMissingMarks;
});

/// 两层筛选聚合结果（docs/10 §4.2）。
class LibraryViewData {
  const LibraryViewData({
    required this.books,
    required this.totalCount,
    required this.statusCounts,
    required this.groupCounts,
  });

  /// 两层取交集后的可见书（保持 watchBooks 的排序与搜索语义）。
  final List<Book> books;

  /// 搜索命中总数（未叠加两层筛选；结果概要「匹配 M / N 本」的 N）。
  final int totalCount;

  /// 状态层分面计数：各 chip 在**当前分组筛选**下的本数。
  final Map<LibraryStatusFilter, int> statusCounts;

  /// 分组层分面计数：各下拉项在**当前状态筛选**下的本数。
  final Map<LibraryGroupFilter, int> groupCounts;
}

/// 两层筛选（A4/A18）：books（SQL 层排序/搜索）× 仅本地标记 × 云端 baseRev
/// × cloudMissingMarks × 分组，全部在内存取交集并算分面计数。
///
/// 数据未就绪（任一 watch 流尚未出首帧）返回 null，由页面自行给加载态。
final filteredLibraryProvider = Provider<LibraryViewData?>((ref) {
  final books = ref.watch(booksStreamProvider).value;
  if (books == null) return null;
  final localOnlyIds =
      ref.watch(localOnlyIdsProvider).value ?? const <String>{};
  final cloudBaseIds =
      ref.watch(cloudBaseIdsProvider).value ?? const <String>{};
  final cloudMissingMarks = ref.watch(cloudMissingMarksProvider);
  final status = ref.watch(libraryStatusFilterProvider);
  final group = ref.watch(libraryGroupFilterProvider);
  final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];

  bool groupMatch(Book book) => groupFilterMatches(group, book);

  final visible = books
      .where(
        (book) =>
            matchesStatusFilter(
              status,
              classifyBookStatus(
                book,
                localOnlyIds: localOnlyIds,
                cloudBaseIds: cloudBaseIds,
                cloudMissingMarks: cloudMissingMarks,
              ),
            ) &&
            groupMatch(book),
      )
      .toList(growable: false);

  final statusCounts = statusFacetCounts(
    books,
    localOnlyIds: localOnlyIds,
    cloudBaseIds: cloudBaseIds,
    cloudMissingMarks: cloudMissingMarks,
    groupMatch: groupMatch,
  );

  // 分组下拉项：全部分组 / 未分组 / 各分组（含计数联动）。
  final groupCounts = <LibraryGroupFilter, int>{
    for (final option in <LibraryGroupFilter>[
      LibraryGroupFilter.all,
      LibraryGroupFilter.ungrouped,
      ...groups.map((g) => GroupFilterSelected(g.groupId)),
    ])
      option: groupFacetCount(
        books,
        status: status,
        localOnlyIds: localOnlyIds,
        cloudBaseIds: cloudBaseIds,
        cloudMissingMarks: cloudMissingMarks,
        groupMatch: (book) => groupFilterMatches(option, book),
      ),
  };

  return LibraryViewData(
    books: visible,
    totalCount: books.length,
    statusCounts: statusCounts,
    groupCounts: groupCounts,
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
    // 「同时上传到云端」开关（docs/10 §4.7c）：取消勾选的书写入仅本地标记表。
    localOnlyDao: ref.watch(databaseProvider).localOnlyBooksDao,
  );
});

/// 仅本地标记 DAO（docs/10 §4.7c）：书库页角标 / 同步页「未上传的书」卡片
/// 据此判定「仅本地」状态。
final localOnlyBooksDaoProvider = Provider<LocalOnlyBooksDao>(
  (ref) => ref.watch(databaseProvider).localOnlyBooksDao,
);

/// 所选导入文件条目（路径 + 展示元数据，Q18 确认弹窗用）。
class ImportFilePick {
  const ImportFilePick({
    required this.path,
    required this.name,
    this.sizeBytes = 0,
  });

  /// 绝对路径（导入流水线输入）。
  final String path;

  /// 文件名（确认弹窗清单展示）。
  final String name;

  /// 字节数（流量预估）；不可读时 0（导入时由流水线计入失败）。
  final int sizeBytes;
}

/// 导入文件选择器抽象（Q18 导入确认弹窗的注入点；测试替换假实现，
/// 不触碰 file_picker 平台通道与真实 IO）。
abstract interface class LibraryFilePicker {
  /// 返回所选文件；用户取消返回空列表。
  Future<List<ImportFilePick>> pickImportFiles();
}

/// 默认实现：file_picker 静态 API（txt/epub/md/pdf）+ stat 文件大小。
final class FilePickerLibraryFilePicker implements LibraryFilePicker {
  const FilePickerLibraryFilePicker();

  @override
  Future<List<ImportFilePick>> pickImportFiles() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'epub', 'md', 'pdf'],
    );
    final picks = <ImportFilePick>[];
    for (final file in picked) {
      final path = file.path;
      if (path == null) continue;
      var sizeBytes = 0;
      try {
        sizeBytes = await File(path).length();
      } catch (_) {
        // 文件不可读：sizeBytes 置 0，导入时由流水线计入失败。
      }
      picks.add(
        ImportFilePick(path: path, name: file.name, sizeBytes: sizeBytes),
      );
    }
    return picks;
  }
}

/// 导入文件选择器 provider。
final libraryFilePickerProvider = Provider<LibraryFilePicker>(
  (ref) => const FilePickerLibraryFilePicker(),
);
