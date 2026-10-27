/// 书库首页（FR-105/106）：网格/列表切换、四种排序、防抖搜索、
/// 本地导入（FR-101/102）与空态引导。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/db/daos/books_dao.dart';
import '../sync/sync_status.dart';
import '../sync/widgets/sync_status_banner.dart';
import 'import/book_import_service.dart';
import 'library_providers.dart';
import 'widgets/book_cards.dart';

/// 书库首页。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// 搜索防抖 300ms（FR-106）后再触发 watchBooks 重查。
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(libraryQueryProvider.notifier).set(value);
    });
  }

  /// 导入书籍（FR-101/102）：文件选择 → 导入流水线 → Snackbar 进度/汇总。
  Future<void> _startImport() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'epub', 'md', 'pdf'],
    );
    // picked 为空 = 用户取消。
    final paths = [
      for (final file in picked)
        if (file.path != null) file.path!,
    ];
    if (paths.isEmpty || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<ImportProgress?>(null);
    final controller = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 10),
        content: ValueListenableBuilder<ImportProgress?>(
          valueListenable: progress,
          builder: (context, current, _) => Text(
            current == null
                ? '准备导入 ${paths.length} 个文件…'
                : '正在导入（${current.completed}/${current.total}）：'
                      '${current.currentName}',
          ),
        ),
      ),
    );
    try {
      final summary = await ref
          .read(bookImportServiceProvider)
          .importFiles(paths, onProgress: (p) => progress.value = p);
      controller.close();
      messenger.showSnackBar(
        SnackBar(
          content: Text(summary.toMessage()),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      controller.close();
      messenger.showSnackBar(
        SnackBar(
          content: Text('导入失败：$e'),
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewMode = ref.watch(libraryViewModeProvider);
    final sort = ref.watch(bookSortProvider);
    final booksAsync = ref.watch(booksStreamProvider);
    final progressMap = ref.watch(progressMapProvider).value;
    final syncStatusMap = ref.watch(bookSyncStatusMapProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SyncReader'),
        actions: [
          PopupMenuButton<BookSort>(
            tooltip: '排序方式',
            icon: const Icon(Icons.sort),
            onSelected: (value) =>
                ref.read(bookSortProvider.notifier).set(value),
            itemBuilder: (context) => [
              for (final value in BookSort.values)
                CheckedPopupMenuItem(
                  value: value,
                  checked: value == sort,
                  child: Text(_sortLabel(value)),
                ),
            ],
          ),
          IconButton(
            tooltip: viewMode == LibraryViewMode.grid ? '切换为列表' : '切换为网格',
            icon: Icon(
              viewMode == LibraryViewMode.grid
                  ? Icons.view_list
                  : Icons.grid_view,
            ),
            onPressed: () => ref
                .read(libraryViewModeProvider.notifier)
                .setMode(
                  viewMode == LibraryViewMode.grid
                      ? LibraryViewMode.list
                      : LibraryViewMode.grid,
                ),
          ),
          IconButton(
            tooltip: '导入书籍',
            icon: const Icon(Icons.add),
            onPressed: _startImport,
          ),
        ],
      ),
      body: Column(
        children: [
          // 全局同步状态横幅（FR-406；点击进同步设置页）。
          const SyncStatusBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索书名或作者',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: booksAsync.when(
              // 静态占位（不用不确定进度圈：本地库毫秒级加载，且避免
              // 永续动画帧导致 pumpAndSettle 不收敛）。
              // Riverpod 3：首帧即失败的流错误停留在
              // AsyncLoading(error) 而非 AsyncError，两种状态都给提示。
              loading: () => _EmptyView(
                hint: booksAsync.hasError
                    ? '书库加载失败：${booksAsync.error}\n请重启应用重试'
                    : '正在加载书库…',
              ),
              // 数据库异常时保持空态标题并给出可操作提示。
              error: (error, _) => _EmptyView(hint: '书库加载失败：$error\n请重启应用重试'),
              data: (books) => books.isEmpty
                  ? const _EmptyView()
                  : switch (viewMode) {
                      LibraryViewMode.grid => _BookGrid(
                        books: books,
                        progressMap: progressMap,
                        syncStatusMap: syncStatusMap,
                      ),
                      LibraryViewMode.list => _BookList(
                        books: books,
                        progressMap: progressMap,
                        syncStatusMap: syncStatusMap,
                      ),
                    },
            ),
          ),
        ],
      ),
    );
  }
}

String _sortLabel(BookSort sort) => switch (sort) {
  BookSort.lastRead => '最近阅读',
  BookSort.title => '书名',
  BookSort.author => '作者',
  BookSort.addedAt => '添加时间',
};

class _EmptyView extends StatelessWidget {
  const _EmptyView({this.hint});

  /// 非空时为错误提示（标题保持"书库为空"以便用户重试导入）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('书库为空', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            hint ?? '点击右上角导入按钮，添加 txt / epub / md / pdf 书籍',
            textAlign: TextAlign.center,
            style: TextStyle(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.books,
    required this.progressMap,
    required this.syncStatusMap,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 150,
        childAspectRatio: 0.58,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return BookGridCard(
          book: book,
          percent: progressMap?[book.bookId]?.percent,
          syncStatus: syncStatusMap[book.bookId],
        );
      },
    );
  }
}

class _BookList extends StatelessWidget {
  const _BookList({
    required this.books,
    required this.progressMap,
    required this.syncStatusMap,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return BookListTile(
          book: book,
          percent: progressMap?[book.bookId]?.percent,
          syncStatus: syncStatusMap[book.bookId],
        );
      },
    );
  }
}
