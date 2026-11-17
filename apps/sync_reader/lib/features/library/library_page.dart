/// 书库首页（FR-105/106 + v1.1 重设计 A3/A4/A5/A6/A13/A17/A18/A20/A21）：
/// 两层筛选（状态 chip × 分组下拉，取交集 + 分面计数）、书卡重做
/// （点封面直接开书 / 右键与长按上下文菜单 / 状态胶囊 / 进度条）、
/// 导入分裂按钮 + 确认弹窗 + 常驻进度条、纸底墨字封面、同步异常提示条。
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/design_tokens.dart';
import '../../core/startup_timer.dart';
import '../../data/db/app_database.dart';
import '../../data/db/daos/books_dao.dart' show BookSort;
import '../../shared/cover_view.dart';
import '../../shared/format_utils.dart';
import '../sync/placeholder_download.dart';
import '../sync/quota_gate.dart';
import '../sync/sync_facade.dart';
import '../sync/sync_status.dart';
import 'group_manage_dialog.dart';
import 'import/batch_import_controller.dart';
import 'import/book_import_service.dart';
import 'library_filters.dart';
import 'library_grid_metrics.dart';
import 'library_providers.dart';
import 'widgets/book_cards.dart';

/// 移动断点（与外壳一致：≤860 底部标签栏；搜索框落内容区、列表隐藏进度条）。
const double _mobileBreakpoint = 860;

/// 「移动到分组」对话框中「未分组」选项的哨兵返回值。
const String _ungroupedSentinel = '__ungrouped__';

/// 书库首页。
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  /// 书卡拖拽进行中（拖拽归组落点栏的显隐开关，FR-107，仅桌面）。
  bool _dragging = false;

  /// 单本/多文件导入进行中的常驻进度（A13；Snackbar 不再承载长任务）。
  ImportProgress? _importProgress;

  /// 已关闭过的提示条文案（同文案不再重复弹出；换文案重新提示）。
  String? _dismissedNotice;

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

  // ── 导入（A13：分裂按钮 + 确认弹窗 + 常驻进度条）────────────────────

  /// 导入文件：文件选择 → Q18 确认弹窗 → 导入流水线（常驻进度）。
  Future<void> _startImport() async {
    if (_importProgress != null) return; // 防重入：一批未完不开下一批。
    final picks = await ref.read(libraryFilePickerProvider).pickImportFiles();
    if (picks.isEmpty || !mounted) return;

    // Q18 确认弹窗：文件清单（名 + 大小）+ 上传勾选（默认勾选）+ 流量预估。
    final uploadToCloud = await showImportConfirmDialog(
      context,
      files: [
        for (final pick in picks)
          ImportFileEntry(name: pick.name, sizeBytes: pick.sizeBytes),
      ],
    );
    if (uploadToCloud == null || !mounted) return; // 用户取消。

    setState(() => _importProgress = null); // 进入常驻进度形态。
    final messenger = ScaffoldMessenger.of(context);
    try {
      final summary = await ref
          .read(bookImportServiceProvider)
          .importFiles(
            [for (final pick in picks) pick.path],
            uploadToCloud: uploadToCloud,
            onProgress: (p) {
              if (mounted) setState(() => _importProgress = p);
            },
          );
      if (mounted) setState(() => _importProgress = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text(_importSummaryText(summary)),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _importProgress = null);
      messenger.showSnackBar(
        SnackBar(
          content: Text('导入失败：$e'),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  /// 导入汇总文案（A13：成功 n / 失败 m，失败列文件名）。
  String _importSummaryText(ImportSummary summary) {
    final lines = <String>[
      '导入完成：成功 ${summary.imported.length} 本，失败 ${summary.failures.length} 本',
    ];
    if (summary.duplicates.isNotEmpty) {
      lines.add('跳过重复 ${summary.duplicates.length} 本');
    }
    for (final entry in summary.failures.entries) {
      lines.add('失败：${entry.key}（${entry.value}）');
    }
    return lines.join('\n');
  }

  // ── 打开书籍（Q15：点封面直接开书）────────────────────────────────

  /// 有正文 → 进阅读器；未下载（仅云端/已删除）→ 先下载，成功后进阅读器。
  void _openBook(Book book) {
    if ((book.localPath ?? '').isNotEmpty) {
      context.push('/reader/${book.bookId}');
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

  // ── 上下文菜单（A20：桌面右键 / 触屏长按，按状态裁剪）───────────────

  Future<void> _showBookContextMenu(Book book, Offset position) async {
    final localOnlyIds =
        ref.read(localOnlyIdsProvider).value ?? const <String>{};
    final cloudBaseIds =
        ref.read(cloudBaseIdsProvider).value ?? const <String>{};
    final bucket = classifyBookStatus(
      book,
      localOnlyIds: localOnlyIds,
      cloudBaseIds: cloudBaseIds,
      cloudMissingMarks: ref.read(cloudMissingMarksProvider),
    );
    final hasContent = (book.localPath ?? '').isNotEmpty;
    final percent = ref.read(progressMapProvider).value?[book.bookId]?.percent;

    final items = <PopupMenuEntry<String>>[
      if (hasContent)
        PopupMenuItem(
          value: 'read',
          child: _menuItemRow(
            Icons.play_arrow_outlined,
            percent != null && percent > 0
                ? '继续阅读（${formatPercent(percent)}）'
                : '开始阅读',
          ),
        )
      else
        const PopupMenuItem(
          value: 'download',
          child: _MenuItemRow(icon: Icons.download_outlined, label: '下载正文'),
        ),
      if (bucket == LibraryStatusBucket.localOnly)
        const PopupMenuItem(
          value: 'upload',
          child: _MenuItemRow(
            icon: Icons.cloud_upload_outlined,
            label: '上传到云端',
          ),
        ),
      PopupMenuItem(
        value: 'info',
        child: _menuItemRow(Icons.menu_book_outlined, '书籍信息'),
      ),
      PopupMenuItem(
        value: 'group',
        child: _menuItemRow(Icons.folder_outlined, '移动到分组…'),
      ),
      if (bucket == LibraryStatusBucket.synced)
        const PopupMenuItem(
          value: 'localonly',
          child: _MenuItemRow(
            icon: Icons.cloud_off_outlined,
            label: '设为仅本地（不上传）',
          ),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: 'delete',
        height: 40,
        child: _MenuItemRow(
          icon: Icons.delete_outline,
          label: '删除本书',
          danger: true,
        ),
      ),
    ];

    final overlay =
        Overlay.of(context, rootOverlay: true).context.findRenderObject()!
            as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        overlay.size.width - position.dx,
        overlay.size.height - position.dy,
      ),
      items: items,
    );
    if (action == null || !mounted) return;
    await _handleMenuAction(book, action);
  }

  Widget _menuItemRow(IconData icon, String label) =>
      _MenuItemRow(icon: icon, label: label);

  Future<void> _handleMenuAction(Book book, String action) async {
    switch (action) {
      case 'read':
        context.push('/reader/${book.bookId}');
      case 'download':
        await downloadPlaceholderBook(
          context,
          ref,
          bookId: book.bookId,
          title: book.title,
        );
      case 'upload':
        await _uploadToCloud(book);
      case 'info':
        context.push('/book/${book.bookId}');
      case 'group':
        await _moveToGroup(book);
      case 'localonly':
        await ref.read(localOnlyBooksDaoProvider).markLocalOnly(book.bookId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已设为仅本地：不会上传到云端，其它设备看不到这本书'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      case 'delete':
        await _confirmDelete(book);
    }
  }

  /// 「上传到云端」（docs/10 §4.7c）：解除仅本地标记 → 清 baseRev → 全量
  /// 同步上架；结果提示（未配置同步/失败 → 可重试）。
  Future<void> _uploadToCloud(Book book) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(syncFacadeProvider).uploadToCloud(book.bookId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? '已上架到云端，其它设备可见' : '上传未完成，可稍后重试'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  /// 「移动到分组…」（FR-107 复用既有归组写库逻辑：setGroup）。
  Future<void> _moveToGroup(Book book) async {
    final groups = ref.read(groupsProvider).value ?? const <BookGroup>[];
    if (!mounted) return;
    final picked = await showDialog<String?>(
      context: context,
      builder: (dialogContext) =>
          _GroupPickerDialog(groups: groups, currentGroupId: book.groupId),
    );
    if (picked == null || !mounted) return; // null = 取消。
    final groupId = picked == _ungroupedSentinel ? null : picked;
    final name = groups
        .where((g) => g.groupId == groupId)
        .map((g) => g.name)
        .firstOrNull;
    await _setBookGroup(context, ref, book.bookId, groupId, name);
  }

  /// 删除确认（文案与详情页一致，docs/10 §4.7b）→ softDelete + 推墓碑。
  Future<void> _confirmDelete(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除《${book.title}》？'),
        content: const Text(
          '删除后的行为：\n'
          '· 本地正文文件立即删除（释放磁盘空间，不可恢复）；\n'
          '· 元数据保留，本书会移到书库的「未下载」区；\n'
          '· 删除标记会同步到云端，其他设备的此书也会从书库移除'
          '（它们的正文文件仍保留）。\n\n'
          '不会删除你磁盘上的原始书籍文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final store = await ref.read(bookFileStoreProvider.future);
    // 与详情页同一路径（docs/10 §4.7b）：删正文/封面文件 + 保留 books 行
    // （落「未下载」区）+ 写墓碑；云端 tombstone 后台推送。
    await ref
        .read(booksDaoProvider)
        .softDelete(book.bookId, removeFiles: store.deleteBookFiles);
    unawaited(ref.read(syncFacadeProvider).deleteBook(book.bookId));
  }

  @override
  Widget build(BuildContext context) {
    final viewMode = ref.watch(libraryViewModeProvider);
    final sort = ref.watch(bookSortProvider);
    final booksAsync = ref.watch(booksStreamProvider);
    final libraryData = ref.watch(filteredLibraryProvider);
    final progressMap = ref.watch(progressMapProvider).value;
    final syncStatusMap = ref.watch(bookSyncStatusMapProvider);
    final localOnlyIds =
        ref.watch(localOnlyIdsProvider).value ?? const <String>{};
    final width = MediaQuery.sizeOf(context).width;
    final narrow = width <= _mobileBreakpoint;
    // 批量导入进行中（FR-109 并发保护）：禁用批量入口与单本导入。
    final batchImporting = ref.watch(
      batchImportControllerProvider.select((s) => s.importing),
    );

    final searchField = TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search, size: 18),
        hintText: '搜索书名或作者',
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('书库'),
        actions: [
          // 搜索框：桌面进顶栏，≤860 落内容区（docs/10 §4.2）。
          if (!narrow)
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.s2),
              child: SizedBox(width: 240, child: searchField),
            ),
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
                  ? Icons.view_list_outlined
                  : Icons.grid_view_outlined,
            ),
            onPressed: () => ref
                .read(libraryViewModeProvider.notifier)
                .setMode(
                  viewMode == LibraryViewMode.grid
                      ? LibraryViewMode.list
                      : LibraryViewMode.grid,
                ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.s3),
            child: _ImportSplitButton(
              disabled: batchImporting || _importProgress != null,
              onPickFiles: _startImport,
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppLayout.contentMaxWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (narrow)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s4,
                    AppSpacing.s3,
                    AppSpacing.s4,
                    0,
                  ),
                  child: searchField,
                ),
              // A3：常驻同步状态条已移出内容区（外壳左下角胶囊承接）；
              // 仅配额超限/同步失败时插入可关闭的提示条。
              _SyncNoticeBar(
                dismissed: _dismissedNotice,
                onDismiss: (text) {
                  setState(() => _dismissedNotice = text);
                },
              ),
              // A13：导入常驻进度条（进行中显示，完成自动消失并汇总）。
              if (_importProgress != null)
                _ImportProgressLine(progress: _importProgress!),
              if (libraryData != null) _FilterBar(data: libraryData),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: AppLayout.contentMaxWidth,
                          ),
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
                            error: (error, _) =>
                                _EmptyView(hint: '书库加载失败：$error\n请重启应用重试'),
                            data: (_) => _buildContent(
                              libraryData: libraryData,
                              progressMap: progressMap,
                              syncStatusMap: syncStatusMap,
                              localOnlyIds: localOnlyIds,
                              viewMode: viewMode,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 拖拽归组落点栏（FR-107，仅桌面拖拽中浮现）。
                    if (_dragging)
                      Positioned(
                        left: AppSpacing.s3,
                        right: AppSpacing.s3,
                        bottom: AppSpacing.s4,
                        child: _GroupDropBar(
                          onAcceptBook: (bookId, groupId, name) =>
                              _setBookGroup(
                                context,
                                ref,
                                bookId,
                                groupId,
                                name,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent({
    required LibraryViewData? libraryData,
    required Map<String, BookProgress>? progressMap,
    required Map<String, BookSyncStatus> syncStatusMap,
    required Set<String> localOnlyIds,
    required LibraryViewMode viewMode,
  }) {
    if (libraryData == null) {
      return const _EmptyView(hint: '正在加载书库…');
    }
    final books = libraryData.books;
    if (books.isEmpty) {
      // 空态分流：真空库 → 导入引导；两层筛选交集为空 → 清除筛选。
      return libraryData.totalCount == 0
          ? const _EmptyView()
          : const _FilterEmptyView();
    }
    return switch (viewMode) {
      LibraryViewMode.grid => _BookGrid(
        books: books,
        progressMap: progressMap,
        syncStatusMap: syncStatusMap,
        localOnlyIds: localOnlyIds,
        onOpen: _openBook,
        onContextMenu: _showBookContextMenu,
        onDragActive: _setDragActive,
      ),
      LibraryViewMode.list => _BookList(
        books: books,
        progressMap: progressMap,
        syncStatusMap: syncStatusMap,
        localOnlyIds: localOnlyIds,
        onOpen: _openBook,
        onContextMenu: _showBookContextMenu,
        onDragActive: _setDragActive,
      ),
    };
  }
}

String _sortLabel(BookSort sort) => switch (sort) {
  BookSort.lastRead => '最近阅读',
  BookSort.title => '书名',
  BookSort.author => '作者',
  BookSort.addedAt => '添加时间',
};

// ═════════════════════════ 筛选（A4/A18）══════════════════════════════

/// 两层筛选栏：状态 chip 行（互斥单选）× 分组下拉 + 结果概要。
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.data});

  final LibraryViewData data;

  /// 管理分组菜单项的哨兵值。
  static const _manageSentinel = '_manage_groups';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    final status = ref.watch(libraryStatusFilterProvider);
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
    final groupFilter = ref.watch(libraryGroupFilterProvider);

    // 选中分组被删除时自动回落「全部」（保持旧版筛选语义）。
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

    String groupLabel(LibraryGroupFilter filter) =>
        groupFilterLabel(filter, groups);

    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final value in LibraryStatusFilter.values) ...[
            _StatusChip(
              label: value.label,
              count: data.statusCounts[value] ?? 0,
              selected: status == value,
              onTap: () =>
                  ref.read(libraryStatusFilterProvider.notifier).set(value),
            ),
            const SizedBox(width: AppSpacing.s2),
          ],
        ],
      ),
    );

    final groupButton = PopupMenuButton<Object>(
      tooltip: '筛选分组',
      onSelected: (value) {
        if (value is LibraryGroupFilter) {
          ref.read(libraryGroupFilterProvider.notifier).set(value);
        } else if (value == _manageSentinel) {
          showGroupManageDialog(context);
        }
      },
      itemBuilder: (context) => [
        for (final option in <LibraryGroupFilter>[
          LibraryGroupFilter.all,
          LibraryGroupFilter.ungrouped,
          ...groups.map((g) => GroupFilterSelected(g.groupId)),
        ])
          PopupMenuItem<Object>(
            value: option,
            child: Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 14,
                  color: groupFilter == option ? t.brandText : t.text3,
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(child: Text(groupLabel(option))),
                Text(
                  '${data.groupCounts[option] ?? 0}',
                  style: t.caption.copyWith(color: t.text3),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<Object>(
          value: _manageSentinel,
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 14),
              SizedBox(width: AppSpacing.s2),
              Text('管理分组…'),
            ],
          ),
        ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
        decoration: BoxDecoration(
          border: Border.all(color: t.border),
          borderRadius: BorderRadius.circular(AppRadius.full),
          color: t.surface,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_outlined, size: 15, color: t.text2),
            const SizedBox(width: 5),
            Text(groupLabel(groupFilter), style: t.sm.copyWith(color: t.text)),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );

    // 结果概要：`共 N 本` 或 `匹配 M / N 本`（M = 两层交集后的可见数）。
    final visible = data.books.length;
    final summary = Text(
      visible == data.totalCount
          ? '共 ${data.totalCount} 本'
          : '匹配 $visible / ${data.totalCount} 本',
      style: t.caption.copyWith(color: t.text3),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s3,
        AppSpacing.s4,
        AppSpacing.s1,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          if (wide) {
            return Row(
              children: [
                Expanded(child: chips),
                const SizedBox(width: AppSpacing.s3),
                groupButton,
                const SizedBox(width: AppSpacing.s3),
                summary,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              chips,
              const SizedBox(height: AppSpacing.s2),
              Row(children: [groupButton, const Spacer(), summary]),
            ],
          );
        },
      ),
    );
  }
}

/// 状态 chip（原型 `.chip`：高 30、胶囊形、选中 brand-soft 底）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Material(
      color: selected ? t.brandSoft : t.surface,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? t.brandSoft2 : t.border),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: t.sm.copyWith(
                  color: selected ? t.brandText : t.text2,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '$count',
                style: t.micro.copyWith(
                  color: selected ? t.brandText : t.text3,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 两层筛选交集为空的空态（原型 `#lib-empty`）。
class _FilterEmptyView extends ConsumerWidget {
  const _FilterEmptyView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: t.surface3,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Icon(Icons.search, size: 30, color: t.text3),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('没有符合条件的书', style: t.h3.copyWith(fontSize: 17)),
          const SizedBox(height: 6),
          Text(
            '当前的状态筛选与分组筛选没有交集，换一个条件试试。',
            style: t.caption.copyWith(color: t.text3),
          ),
          const SizedBox(height: AppSpacing.s5),
          OutlinedButton(
            onPressed: () {
              ref
                  .read(libraryStatusFilterProvider.notifier)
                  .set(LibraryStatusFilter.all);
              ref
                  .read(libraryGroupFilterProvider.notifier)
                  .set(LibraryGroupFilter.all);
            },
            child: const Text('清除筛选'),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════ 提示条与导入进度（A3/A13）══════════════════════

/// 同步异常提示条（A3）：仅配额超限或同步失败时出现，可关闭；
/// 其余状态完全交给外壳左下角胶囊。
class _SyncNoticeBar extends ConsumerWidget {
  const _SyncNoticeBar({required this.dismissed, required this.onDismiss});

  /// 当前被用户关闭过的文案（同文案不再重复提示）。
  final String? dismissed;

  /// 关闭回调（参数为被关闭的文案，由页面记录）。
  final void Function(String text) onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    final memory = ref.watch(syncMemoryStatusProvider);
    // 配额告警链路：内存侧实时告警优先，持久化快照推导兜底（冷启动）。
    final snap = ref.watch(quotaSnapshotProvider).value;
    final quotaWarn =
        memory.quotaWarnText ??
        (snap == null ? null : SyncQuotaGate.warnText(snap));
    final failed = memory.id == SyncStateId.failed;
    final text = failed ? '同步失败：${memory.failureText ?? '未知原因'}' : quotaWarn;
    if (text == null || text.isEmpty || text == dismissed) {
      return const SizedBox.shrink();
    }
    final color = failed ? t.danger : t.warn;
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s3,
        AppSpacing.s4,
        0,
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s3,
        AppSpacing.s2,
        AppSpacing.s1,
        AppSpacing.s2,
      ),
      decoration: BoxDecoration(
        color: failed ? t.dangerSoft : t.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            failed ? Icons.cloud_off : Icons.warning_amber_outlined,
            size: 18,
            color: color,
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            icon: Icon(Icons.close, size: 16, color: color),
            onPressed: () => onDismiss(text),
          ),
        ],
      ),
    );
  }
}

/// 导入常驻进度条（A13）：x/y 文件 + 当前文件名，完成自动消失。
class _ImportProgressLine extends StatelessWidget {
  const _ImportProgressLine({required this.progress});

  final ImportProgress progress;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s4,
        AppSpacing.s2,
        AppSpacing.s4,
        0,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: LinearProgressIndicator(
              value: progress.total > 0
                  ? progress.completed / progress.total
                  : null,
              minHeight: 3,
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              '正在导入（${progress.completed}/${progress.total}）：'
              '${progress.currentName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.caption.copyWith(color: t.text2),
            ),
          ),
        ],
      ),
    );
  }
}

/// 导入分裂按钮（A13）：主区「＋ 导入」= 导入文件；箭头展开
/// 「导入文件… / 批量导入（文件夹）」。
class _ImportSplitButton extends StatelessWidget {
  const _ImportSplitButton({required this.disabled, required this.onPickFiles});

  /// 批量导入或单本导入进行中 → 整体禁用（FR-109 防重入）。
  final bool disabled;

  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final onBrand = t.isDark ? const Color(0xFF06231F) : Colors.white;
    final menuPart = PopupMenuButton<String>(
      tooltip: '更多导入方式',
      enabled: !disabled,
      color: t.surface,
      onSelected: (value) {
        if (value == 'pick') onPickFiles();
        if (value == 'batch') context.go('/tools/batch-import');
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'pick', child: Text('导入文件…')),
        PopupMenuItem(value: 'batch', child: Text('批量导入（文件夹）')),
      ],
      icon: Icon(Icons.arrow_drop_down, color: onBrand),
    );
    return Material(
      color: disabled ? t.surface3 : t.brand,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: const Key('library-import-main'),
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(AppRadius.md),
            ),
            onTap: disabled ? null : onPickFiles,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3,
                vertical: 7,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16, color: onBrand),
                  const SizedBox(width: 4),
                  Text(
                    '导入',
                    style: t.sm.copyWith(
                      color: onBrand,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Container(
            width: 1,
            height: 20,
            color: onBrand.withValues(alpha: 0.35),
          ),
          menuPart,
        ],
      ),
    );
  }
}

// ═════════════════════════ 导入确认弹窗（Q18）════════════════════════

/// 导入确认弹窗的文件条目。
class ImportFileEntry {
  const ImportFileEntry({required this.name, required this.sizeBytes});

  final String name;
  final int sizeBytes;
}

/// Q18 导入确认弹窗：文件清单（名 + 大小）+「同时上传到云端」勾选
/// （**默认勾选**）+ 上行流量预估。返回 null = 取消；true = 同时上传；
/// false = 只留在本机（标记「仅本地」）。
Future<bool?> showImportConfirmDialog(
  BuildContext context, {
  required List<ImportFileEntry> files,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => ImportConfirmDialog(files: files),
  );
}

/// 导入确认弹窗本体（公开给测试直接泵入）。
class ImportConfirmDialog extends StatefulWidget {
  const ImportConfirmDialog({super.key, required this.files});

  final List<ImportFileEntry> files;

  @override
  State<ImportConfirmDialog> createState() => _ImportConfirmDialogState();
}

class _ImportConfirmDialogState extends State<ImportConfirmDialog> {
  // Q18：默认勾选「同时上传到云端」。
  bool _uploadToCloud = true;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final totalBytes = widget.files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
    return AlertDialog(
      title: const Text('导入书籍'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.files.length,
                  itemBuilder: (context, index) {
                    final file = widget.files[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              file.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.sm.copyWith(color: t.text),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.s3),
                          Text(
                            humanizeBytes(file.sizeBytes),
                            style: t.caption.copyWith(color: t.text3),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            CheckboxListTile(
              value: _uploadToCloud,
              // Q18 取消勾选的语义说明（docs/10 §4.7c）。
              subtitle: const Text(
                '勾选后本次导入的书会推送到云端，其它设备即可同步。'
                '取消则只留在本机（标记为「仅本地」），可随时再上传。',
              ),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                '同时上传到云端',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              onChanged: (value) =>
                  setState(() => _uploadToCloud = value ?? true),
            ),
            const SizedBox(height: AppSpacing.s1),
            Text(
              _uploadToCloud
                  ? uploadEstimateText(totalBytes)
                  : '不上传：不消耗上行流量，其它设备看不到这几本书',
              style: t.caption.copyWith(
                color: _uploadToCloud ? t.text3 : t.warn,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_uploadToCloud),
          child: Text('导入 ${widget.files.length} 本'),
        ),
      ],
    );
  }
}

// ═════════════════════════ 网格 / 列表（A5/A6/A20）════════════════════

class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.books,
    required this.progressMap,
    required this.syncStatusMap,
    required this.localOnlyIds,
    required this.onOpen,
    required this.onContextMenu,
    required this.onDragActive,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;
  final Set<String> localOnlyIds;

  final void Function(Book book) onOpen;
  final void Function(Book book, Offset position) onContextMenu;
  final void Function(bool active) onDragActive;

  @override
  Widget build(BuildContext context) {
    // 列数 / 卡宽 / 卡高 / 一屏几行统一由度量模块给出（v1.3.4 密度整改）：
    // 改造前页面按 `ceil(内容宽 / 176)` 算宽高比、委托却按
    // `ceil(内容宽 / (176 + 16))` 排布，手机实得 2 列 × 1.5 行 ≈ 3 本。
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = computeLibraryGridMetrics(
          viewportWidth: constraints.maxWidth,
          viewportHeight: constraints.hasBoundedHeight
              ? constraints.maxHeight
              : double.infinity,
          spec: libraryGridSpecForWidth(constraints.maxWidth),
        );
        return GridView.builder(
          padding: EdgeInsets.all(metrics.padding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: metrics.columns,
            childAspectRatio: metrics.childAspectRatio,
            crossAxisSpacing: metrics.crossAxisSpacing,
            mainAxisSpacing: metrics.mainAxisSpacing,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) => _buildCard(books[index], metrics),
        );
      },
    );
  }

  Widget _buildCard(Book book, LibraryGridMetrics metrics) {
    final percent = progressMap?[book.bookId]?.percent;
    final card = BookGridCard(
      book: book,
      percent: percent,
      syncStatus: syncStatusMap[book.bookId],
      localOnly: localOnlyIds.contains(book.bookId),
      onOpen: () => onOpen(book),
      onContextMenu: (position) => onContextMenu(book, position),
      compact: metrics.overlayTitle,
      coverAspectRatio: metrics.coverAspectRatio,
    );
    // 桌面保留拖拽归组（FR-107）；触屏长按出菜单（A20 冲突解法）。
    return _MouseLongPressDraggable(
      data: book.bookId,
      onDragActive: onDragActive,
      childWhenDragging: Opacity(opacity: 0.4, child: card),
      feedback: _DragFeedback(book: book),
      child: card,
    );
  }
}

class _BookList extends StatelessWidget {
  const _BookList({
    required this.books,
    required this.progressMap,
    required this.syncStatusMap,
    required this.localOnlyIds,
    required this.onOpen,
    required this.onContextMenu,
    required this.onDragActive,
  });

  final List<Book> books;
  final Map<String, BookProgress>? progressMap;
  final Map<String, BookSyncStatus> syncStatusMap;
  final Set<String> localOnlyIds;

  final void Function(Book book) onOpen;
  final void Function(Book book, Offset position) onContextMenu;
  final void Function(bool active) onDragActive;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        final percent = progressMap?[book.bookId]?.percent;
        final tile = BookListTile(
          book: book,
          percent: percent,
          syncStatus: syncStatusMap[book.bookId],
          localOnly: localOnlyIds.contains(book.bookId),
          onOpen: () => onOpen(book),
          onContextMenu: (position) => onContextMenu(book, position),
        );
        return _MouseLongPressDraggable(
          data: book.bookId,
          onDragActive: onDragActive,
          childWhenDragging: Opacity(opacity: 0.4, child: tile),
          feedback: _DragFeedback(book: book),
          child: tile,
        );
      },
    );
  }
}

// ═════════════════════════ 空态 / 拖拽归组 ═══════════════════════════

class _EmptyView extends StatelessWidget {
  const _EmptyView({this.hint});

  /// 非空时为错误提示（标题保持"书库为空"以便用户重试导入）。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: t.surface3,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Icon(Icons.menu_book_outlined, size: 30, color: t.text3),
          ),
          const SizedBox(height: AppSpacing.s5),
          Text('书库为空', style: t.h3.copyWith(fontSize: 17)),
          const SizedBox(height: AppSpacing.s2),
          Text(
            hint ?? '点击右上角导入按钮，添加 txt / epub / md / pdf 书籍',
            textAlign: TextAlign.center,
            style: t.caption.copyWith(color: t.text3),
          ),
        ],
      ),
    );
  }
}

/// 落点归组（FR-107）：写库后 SnackBar 反馈；[name] 为 null = 移出分组。
/// 分组参与云端同步（docs/05 §2.1）：归组后立即推该书的 meta（携带
/// groupId），失败不影响本地，下次全量同步按 dirty 补推（本地优先）。
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
    // 归组变更上云（FR-107）：书籍 meta 携带 groupId。
    unawaited(ref.read(syncFacadeProvider).pushBookMeta(bookId));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('分组操作失败：$e')));
  }
}

/// 「移动到分组」选择对话框（A20 菜单入口；列表含「未分组」）。
class _GroupPickerDialog extends StatelessWidget {
  const _GroupPickerDialog({required this.groups, this.currentGroupId});

  final List<BookGroup> groups;
  final String? currentGroupId;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return AlertDialog(
      title: const Text('移动到分组'),
      content: SizedBox(
        width: 280,
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              dense: true,
              leading: Icon(
                Icons.folder_off_outlined,
                size: 18,
                color: currentGroupId == null ? t.brand : t.text2,
              ),
              title: const Text('未分组'),
              trailing: currentGroupId == null
                  ? Icon(Icons.check, size: 18, color: t.brand)
                  : null,
              onTap: () => Navigator.of(context).pop(_ungroupedSentinel),
            ),
            for (final group in groups)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.folder_outlined,
                  size: 18,
                  color: group.groupId == currentGroupId ? t.brand : t.text2,
                ),
                title: Text(group.name),
                trailing: group.groupId == currentGroupId
                    ? Icon(Icons.check, size: 18, color: t.brand)
                    : null,
                onTap: () => Navigator.of(context).pop(group.groupId),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
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
    final t = context.appTokens;
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(AppRadius.md),
      color: t.surface2,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: AppSpacing.s3),
              child: Icon(Icons.drag_indicator, size: 18),
            ),
            const SizedBox(width: AppSpacing.s1),
            Text('拖到分组归组', style: t.caption.copyWith(color: t.text2)),
            const SizedBox(width: AppSpacing.s2),
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

/// 落点 chip（拖拽归组栏内，FR-107）：拖拽悬停高亮提示可放下，落下触发
/// [onAcceptBook]；无筛选语义（筛选在筛选栏）。
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

// ═══════════════════ FR-107 × A20 手势冲突解法 ═══════════════════════

/// 仅鼠标指针加入手势竞技场的长按拖拽识别器：触屏/笔的长按不进竞技场，
/// 让给书卡的上下文菜单（[TouchLongPressMenu]）——桌面保留拖拽归组 +
/// 右键菜单，触屏取消拖拽归组、统一走菜单「移动到分组…」（docs/10 §4.2）。
class _MouseOnlyDelayedMultiDragGestureRecognizer
    extends DelayedMultiDragGestureRecognizer {
  _MouseOnlyDelayedMultiDragGestureRecognizer() : super();

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      event.kind == PointerDeviceKind.mouse && super.isPointerAllowed(event);
}

/// 长按拖拽书卡（FR-107，仅鼠标）：data 为 bookId，feedback 为缩小带阴影
/// 封面。childWhenDragging 半透明标记"已拿起"（由调用方传入包裹后的
/// 卡片）；拖拽起止经 [onDragActive] 通知书库页显隐落点栏。
class _MouseLongPressDraggable extends LongPressDraggable<String> {
  _MouseLongPressDraggable({
    required super.data,
    required super.child,
    required super.childWhenDragging,
    required super.feedback,
    required void Function(bool active) onDragActive,
  }) : super(
         onDragStarted: () => onDragActive(true),
         onDragEnd: (_) => onDragActive(false),
         onDraggableCanceled: (_, _) => onDragActive(false),
       );

  @override
  DelayedMultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _MouseOnlyDelayedMultiDragGestureRecognizer()..onStart = onStart;
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
      borderRadius: BorderRadius.circular(AppRadius.md),
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

/// 上下文菜单行（图标 + 文字；危险色标红）。
class _MenuItemRow extends StatelessWidget {
  const _MenuItemRow({
    required this.icon,
    required this.label,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final color = danger ? t.danger : t.text;
    return Row(
      children: [
        Icon(icon, size: 15, color: danger ? t.danger : t.text2),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text(label, style: t.sm.copyWith(color: color)),
        ),
      ],
    );
  }
}
