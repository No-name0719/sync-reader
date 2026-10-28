/// 书库首页（FR-105/106）：网格/列表切换、四种排序、防抖搜索、
/// 本地导入（FR-101/102）与空态引导。
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/app_database.dart';
import '../../data/db/daos/books_dao.dart';
import '../../app/providers.dart';
import '../../core/startup_timer.dart';
import '../../shared/cover_view.dart';
import '../sync/placeholder_download.dart';
import '../sync/sync_status.dart';
import '../sync/widgets/sync_status_banner.dart';
import 'import/book_import_service.dart';
import 'import/batch_import_controller.dart';
import 'import/batch_import_page.dart';
import 'group_manage_dialog.dart';
import 'library_providers.dart';
import 'orphan/orphan_files_page.dart';
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
  void initState() {
    super.initState();
    // 书库首建打点（NFR-05 辅助口径；同名点只记首次，重复进入不覆盖）。
    startupTimer.mark('libraryFirstBuild');
  }

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

  /// 批量导入入口（FR-109）：选目录 → 推送清单确认页。
  /// 用户取消选择时静默返回；目录经 provider 注入，测试可替换假实现。
  Future<void> _startBatchImport() async {
    final directoryPath = await ref
        .read(directoryPickerProvider)
        .pickDirectory();
    if (directoryPath == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            BatchImportConfirmationPage(directoryPath: directoryPath),
      ),
    );
  }

  /// 游离文件管理入口（FR-408）：本地孤儿正文的清单/挂回/清理。
  Future<void> _openOrphanFiles() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const OrphanFilesPage()));
  }

  /// 点开书籍（FR-402 分流）：有正文 → 详情页（现有点开即读链路）；
  /// 占位书（localPath 为空）→ 触发云端正文下载，成功后直接进阅读页
  /// （阅读器不接收无正文的书），失败保持占位可重试。
  void _openBook(Book book) {
    if ((book.localPath ?? '').isNotEmpty) {
      context.push('/book/${book.bookId}');
      return;
    }
    unawaited(_downloadPlaceholderAndOpen(book));
  }

  Future<void> _downloadPlaceholderAndOpen(Book book) async {
    final ok = await downloadPlaceholderBook(
      context,
      ref,
      bookId: book.bookId,
      title: book.title,
    );
    if (!ok || !mounted) return;
    context.push('/reader/${book.bookId}');
  }

  @override
  Widget build(BuildContext context) {
    final viewMode = ref.watch(libraryViewModeProvider);
    final sort = ref.watch(bookSortProvider);
    final booksAsync = ref.watch(booksStreamProvider);
    final progressMap = ref.watch(progressMapProvider).value;
    final syncStatusMap = ref.watch(bookSyncStatusMapProvider);
    // 批量导入进行中（FR-109 并发保护）：禁用批量入口与单本导入，
    // 防止两条导入流水线并发写库。
    final batchImporting = ref.watch(
      batchImportControllerProvider.select((s) => s.importing),
    );

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
            onPressed: batchImporting ? null : _startImport,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'batch_import') _startBatchImport();
              if (value == 'orphan_files') _openOrphanFiles();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'batch_import',
                enabled: !batchImporting,
                child: const Text('批量导入（文件夹）'),
              ),
              PopupMenuItem(
                value: 'orphan_files',
                enabled: !batchImporting,
                child: const Text('游离文件管理'),
              ),
            ],
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
          // 分组过滤栏（FR-107）：书卡可长按拖入 chip 归组。
          const _GroupFilterBar(),
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
                        onOpen: _openBook,
                      ),
                      LibraryViewMode.list => _BookList(
                        books: books,
                        progressMap: progressMap,
                        syncStatusMap: syncStatusMap,
                        onOpen: _openBook,
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
    required this.onOpen,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  /// 点开回调（书库页分流：占位书下载 / 普通书进详情）。
  final void Function(Book book) onOpen;

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
        return _DraggableBook(
          book: book,
          child: BookGridCard(
            book: book,
            percent: progressMap?[book.bookId]?.percent,
            syncStatus: syncStatusMap[book.bookId],
            onOpen: () => onOpen(book),
          ),
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
    required this.onOpen,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  /// 点开回调（书库页分流：占位书下载 / 普通书进详情）。
  final void Function(Book book) onOpen;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return _DraggableBook(
          book: book,
          child: BookListTile(
            book: book,
            percent: progressMap?[book.bookId]?.percent,
            syncStatus: syncStatusMap[book.bookId],
            onOpen: () => onOpen(book),
          ),
        );
      },
    );
  }
}

/// 分组过滤栏（FR-107）：`[全部][未分组][分组A…] [管理]` 横向滚动一行，
/// 位于搜索栏与书列表之间。分组 chip 兼作拖拽落点（书卡长按拖入归组，
/// 拖入「未分组」移出分组；「全部」不接收拖拽）。
class _GroupFilterBar extends ConsumerWidget {
  const _GroupFilterBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryGroupFilterProvider);
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
    // 选中分组被删除时回落「全部」，避免书列表停在空过滤视图。
    ref.listen(groupsProvider, (_, next) {
      final list = next.value;
      if (list == null) return;
      final current = ref.read(libraryGroupFilterProvider);
      if (current is GroupFilterSelected &&
          !list.any((g) => g.groupId == current.groupId)) {
        ref
            .read(libraryGroupFilterProvider.notifier)
            .set(LibraryGroupFilter.all);
      }
    });
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        children: [
          ChoiceChip(
            label: const Text('全部'),
            selected: filter == LibraryGroupFilter.all,
            onSelected: (_) => ref
                .read(libraryGroupFilterProvider.notifier)
                .set(LibraryGroupFilter.all),
          ),
          const SizedBox(width: 6),
          _GroupDropChip(
            label: '未分组',
            selected: filter == LibraryGroupFilter.ungrouped,
            onSelect: () => ref
                .read(libraryGroupFilterProvider.notifier)
                .set(LibraryGroupFilter.ungrouped),
            onAcceptBook: (bookId) =>
                _setBookGroup(context, ref, bookId, null, null),
          ),
          const SizedBox(width: 6),
          for (final group in groups) ...[
            _GroupDropChip(
              key: ValueKey(group.groupId),
              label: group.name,
              selected:
                  filter is GroupFilterSelected &&
                  filter.groupId == group.groupId,
              onSelect: () => ref
                  .read(libraryGroupFilterProvider.notifier)
                  .set(GroupFilterSelected(group.groupId)),
              onAcceptBook: (bookId) => _setBookGroup(
                context,
                ref,
                bookId,
                group.groupId,
                group.name,
              ),
            ),
            const SizedBox(width: 6),
          ],
          ActionChip(
            avatar: const Icon(Icons.folder_open, size: 18),
            label: const Text('管理'),
            tooltip: '管理分组',
            onPressed: () => showGroupManageDialog(context),
          ),
        ],
      ),
    );
  }
}

/// 落点归组（FR-107）：写库后 SnackBar 反馈；[name] 为 null = 移出分组
/// （「未分组」chip）。分组纯本地（v1 不入同步），只调本地 DAO。
Future<void> _setBookGroup(
  BuildContext context,
  WidgetRef ref,
  String bookId,
  String? groupId,
  String? name,
) async {
  // ref/messenger 先取（跨 await 使用页面 ref 会随组件销毁失效）。
  final dao = ref.read(booksDaoProvider);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await dao.setGroup(bookId, groupId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(name == null ? '已移出分组' : '已移入「$name」'),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('分组操作失败：$e')));
  }
}

/// 分组 chip + 拖拽落点（FR-107）：拖拽悬停时 chip 呈选中态高亮提示
/// 可放下，落下触发 [onAcceptBook]。
class _GroupDropChip extends StatefulWidget {
  const _GroupDropChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelect,
    required this.onAcceptBook,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelect;
  final Future<void> Function(String bookId) onAcceptBook;

  @override
  State<_GroupDropChip> createState() => _GroupDropChipState();
}

class _GroupDropChipState extends State<_GroupDropChip> {
  /// 拖拽悬停中（高亮落点）。
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) {
        setState(() => _hovering = true);
        return true;
      },
      onLeave: (_) {
        if (mounted) setState(() => _hovering = false);
      },
      onAcceptWithDetails: (details) {
        setState(() => _hovering = false);
        widget.onAcceptBook(details.data);
      },
      builder: (context, _, _) => ChoiceChip(
        label: Text(widget.label),
        // 悬停即借用选中态高亮（ChoiceChip 默认视觉）。
        selected: widget.selected || _hovering,
        onSelected: (_) => widget.onSelect(),
      ),
    );
  }
}

/// 长按拖拽书卡（FR-107）：data 为 bookId，feedback 为缩小带阴影封面。
/// Draggable 不拦截短按（点开详情不受影响），长按阈值也保证列表滚动
/// 不误触发；childWhenDragging 半透明标记"已拿起"。
class _DraggableBook extends StatelessWidget {
  const _DraggableBook({required this.book, required this.child});

  final Book book;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<String>(
      data: book.bookId,
      // feedback 随手指，起点即卡片原位附近（默认 pointer 锚点即可）。
      feedback: _DragFeedback(book: book),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

/// 拖拽跟随的小卡片：固定尺寸（Overlay 约束松散，网格卡内含 Expanded
/// 不能直接复用），封面 + 阴影表达"拿起一本书"。
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 84,
        height: 118,
        child: CoverView(
          coverPath: book.coverPath,
          title: book.title,
          author: book.author,
          contentHash: book.contentHash,
        ),
      ),
    );
  }
}
