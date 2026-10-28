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

  /// 书卡拖拽进行中（拖拽归组落点栏的显隐开关，FR-107）。
  bool _dragging = false;

  void _setDragActive(bool active) {
    if (_dragging == active) return;
    setState(() => _dragging = active);
  }

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
        // 无标题（应用名不在书库页展示，右上角让位给筛选入口）。
        actions: [
          const _FilterMenuButton(),
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
          // 拖拽归组落点栏（FR-107）：仅书卡拖拽进行中浮现，平时不占版面；
          // 筛选本身在右上角 AppBar（[_FilterMenuButton]）。
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
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
                    error: (error, _) =>
                        _EmptyView(hint: '书库加载失败：$error\n请重启应用重试'),
                    data: (books) => books.isEmpty
                        ? const _EmptyView()
                        : switch (viewMode) {
                            LibraryViewMode.grid => _BookGrid(
                              books: books,
                              progressMap: progressMap,
                              syncStatusMap: syncStatusMap,
                              onOpen: _openBook,
                              onDragActive: _setDragActive,
                            ),
                            LibraryViewMode.list => _BookList(
                              books: books,
                              progressMap: progressMap,
                              syncStatusMap: syncStatusMap,
                              onOpen: _openBook,
                              onDragActive: _setDragActive,
                            ),
                          },
                  ),
                ),
                if (_dragging)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: _GroupDropBar(
                      onAcceptBook: (bookId, groupId, name) =>
                          _setBookGroup(context, ref, bookId, groupId, name),
                    ),
                  ),
              ],
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
    required this.onDragActive,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  /// 点开回调（书库页分流：占位书下载 / 普通书进详情）。
  final void Function(Book book) onOpen;

  /// 拖拽起止回调（落点栏显隐，FR-107）。
  final void Function(bool active) onDragActive;

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
          onDragActive: onDragActive,
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
    required this.onDragActive,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;

  /// 点开回调（书库页分流：占位书下载 / 普通书进详情）。
  final void Function(Book book) onOpen;

  /// 拖拽起止回调（落点栏显隐，FR-107）。
  final void Function(bool active) onDragActive;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return _DraggableBook(
          book: book,
          onDragActive: onDragActive,
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

/// 右上角筛选入口（FR-107/FR-402）：`筛选：当前值 ▾` 下拉菜单，四选一
/// 互斥——全部 / 未分组 / 未下载 / 各分组；菜单底部带「管理分组…」。
/// 选中分组被删除时自动回落「全部」，避免书列表停在空过滤视图。
class _FilterMenuButton extends ConsumerWidget {
  const _FilterMenuButton();

  /// 管理分组菜单项的哨兵值（与 LibraryGroupFilter 值共用 Object 载体）。
  static const _manageSentinel = '_manage_groups';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryGroupFilterProvider);
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
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

    String labelFor(LibraryGroupFilter f) => switch (f) {
      LibraryGroupFilter.all => '全部',
      LibraryGroupFilter.ungrouped => '未分组',
      LibraryGroupFilter.undownloaded => '未下载',
      GroupFilterSelected(:final groupId) =>
        groups.any((g) => g.groupId == groupId)
            ? '分组：${groups.firstWhere((g) => g.groupId == groupId).name}'
            : '全部',
      // 面常量已命中全部取值，通配兜底仅满足 sealed 穷尽性。
      _ => '全部',
    };
    return PopupMenuButton<Object>(
      tooltip: '筛选书库',
      onSelected: (value) {
        if (value is LibraryGroupFilter) {
          ref.read(libraryGroupFilterProvider.notifier).set(value);
        } else if (value == _manageSentinel) {
          showGroupManageDialog(context);
        }
      },
      itemBuilder: (context) => [
        _filterItem('全部', LibraryGroupFilter.all, filter),
        _filterItem('未分组', LibraryGroupFilter.ungrouped, filter),
        _filterItem('未下载', LibraryGroupFilter.undownloaded, filter),
        if (groups.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final group in groups)
            CheckedPopupMenuItem<Object>(
              value: GroupFilterSelected(group.groupId),
              checked:
                  filter is GroupFilterSelected &&
                  filter.groupId == group.groupId,
              child: Text(group.name),
            ),
        ],
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: _manageSentinel,
          child: ListTile(
            leading: Icon(Icons.folder_open),
            title: Text('管理分组…'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list, size: 20),
            const SizedBox(width: 4),
            Text(labelFor(filter)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<Object> _filterItem(
    String label,
    LibraryGroupFilter value,
    LibraryGroupFilter current,
  ) => CheckedPopupMenuItem<Object>(
    value: value,
    checked: current == value,
    child: Text(label),
  );
}

/// 拖拽归组落点栏（FR-107）：书卡拖拽进行中浮现于书库底部，横排各分组
/// 与「未分组」落点 chip；书卡移入即归组，移入「未分组」移出分组。
class _GroupDropBar extends ConsumerWidget {
  const _GroupDropBar({required this.onAcceptBook});

  /// [groupId] 为 null = 移出分组。
  final void Function(String bookId, String? groupId, String? name)
  onAcceptBook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(Icons.drag_indicator, size: 18),
            ),
            const SizedBox(width: 4),
            Text('拖到分组归组', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 8),
            Expanded(
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: [
                  for (final group in groups) ...[
                    _GroupDropChip(
                      key: ValueKey(group.groupId),
                      label: group.name,
                      onAcceptBook: (bookId) =>
                          onAcceptBook(bookId, group.groupId, group.name),
                    ),
                    const SizedBox(width: 6),
                  ],
                  _GroupDropChip(
                    label: '未分组',
                    onAcceptBook: (bookId) => onAcceptBook(bookId, null, null),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ],
        ),
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

/// 落点 chip（拖拽归组栏内，FR-107）：拖拽悬停高亮提示可放下，落下触发
/// [onAcceptBook]；无筛选语义（筛选在右上角下拉）。
class _GroupDropChip extends StatefulWidget {
  const _GroupDropChip({
    super.key,
    required this.label,
    required this.onAcceptBook,
  });

  final String label;
  final void Function(String bookId) onAcceptBook;

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
        // 悬停高亮提示落点（ChoiceChip 选中态视觉）。
        selected: _hovering,
        onSelected: (_) {},
      ),
    );
  }
}

/// 长按拖拽书卡（FR-107）：data 为 bookId，feedback 为缩小带阴影封面。
/// Draggable 不拦截短按（点开详情不受影响），长按阈值也保证列表滚动
/// 不误触发；childWhenDragging 半透明标记"已拿起"。拖拽起止经
/// [onDragActive] 通知书库页显隐落点栏。
class _DraggableBook extends StatelessWidget {
  const _DraggableBook({
    required this.book,
    required this.child,
    required this.onDragActive,
  });

  final Book book;
  final Widget child;
  final void Function(bool active) onDragActive;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<String>(
      data: book.bookId,
      // feedback 随手指，起点即卡片原位附近（默认 pointer 锚点即可）。
      feedback: _DragFeedback(book: book),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      onDragStarted: () => onDragActive(true),
      onDragEnd: (_) => onDragActive(false),
      onDraggableCanceled: (_, _) => onDragActive(false),
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
