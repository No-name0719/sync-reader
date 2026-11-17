/// 云端书库管理页（v1.1 新增，docs/10 §4.8 / Q16 / Q19，A16）：
/// 从云端视角管理书目——书库页只能看到本地有的书，这里列出云端**全部**
/// 未删除的 meta（含其它设备上传的、本端没有的书）。
///
/// 删除语义（Q19，与 `deleteBook` 的 tombstone 全局删除严格区分）：
/// 本页只调 [SyncFacade.removeFromCloud]（= `BackendAdapter.deleteMeta`，
/// 不写 tombstone）——各端本地副本保留、照常可读，但也不会自动再传回云端；
/// 任一端可随时重新上传。各端落 diff 第 7b 行的行为由数据层保证（baseRev
/// 保留），页面不额外处理。
///
/// 视觉对齐原型「云端书库」屏（ui_prototype/index.html，content-inner
/// 860px）：顶部 info 说明条 + 清单卡（勾选框 + 书名 + 格式·大小 + 本地状态
/// 胶囊 + 行内「从云端移除」）+ 底部操作条（已选 n 项 / 全选 / 危险色批量移除）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/providers.dart';
import '../../../core/design_tokens.dart';
import '../../../shared/format_utils.dart';
import '../sync_facade.dart';

/// 云端书目清单（未配置 / 清单失败 → null）。
final cloudBooksProvider = FutureProvider.autoDispose<List<CloudBookSummary>?>((
  ref,
) {
  return ref.watch(syncFacadeProvider).listCloudBooks();
});

/// books 表快照（本地状态胶囊判定）：bookId → 本地是否有正文。
///
/// `localPath` 非空 = 本地已下载；空（占位书 / 已删除）= 仅云端。
final cloudLocalStateProvider = StreamProvider.autoDispose<Map<String, bool>>((
  ref,
) {
  final db = ref.watch(databaseProvider);
  return db.booksDao.watchBooks().map(
    (books) => {
      for (final book in books) book.bookId: (book.localPath ?? '').isNotEmpty,
    },
  );
});

/// 云端书库管理页（shell 内路由 `/sync/cloudlib`）。
class CloudLibraryPage extends ConsumerStatefulWidget {
  const CloudLibraryPage({super.key});

  @override
  ConsumerState<CloudLibraryPage> createState() => _CloudLibraryPageState();
}

class _CloudLibraryPageState extends ConsumerState<CloudLibraryPage> {
  /// 勾选待移除的 bookId 集合。
  final Set<String> _selected = {};

  /// 行内移除进行中的 bookId（该行按钮转圈、其它入口冻结）。
  final Set<String> _rowBusy = {};

  /// 批量移除进行中（进度 x/y）。
  int _batchDone = 0;
  int _batchTotal = 0;
  bool _batchRunning = false;

  bool get _busy => _batchRunning || _rowBusy.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(syncConfigProvider);
    final booksAsync = ref.watch(cloudBooksProvider);
    final localAsync = ref.watch(cloudLocalStateProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('云端书库')),
      body: configAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _GuideView(
          icon: Icons.cloud_off_outlined,
          title: '无法确认同步配置',
          desc: '读取同步配置失败',
          actionLabel: '重试',
          onAction: () => ref.invalidate(syncConfigProvider),
        ),
        data: (config) {
          // 未配置同步 → 引导态（§4.8：先去配置，再回来管理）。
          if (config == null) {
            return const _GuideView(
              icon: Icons.cloud_off_outlined,
              title: '尚未配置同步',
              desc: '配置坚果云账号后，这里会列出云端全部书籍。',
              actionLabel: '去配置',
              route: '/sync/guide',
            );
          }
          return booksAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => _GuideView(
              icon: Icons.error_outline,
              title: '清单获取失败',
              desc: '无法读取云端书目，请检查网络后重试',
              actionLabel: '重试',
              onAction: () => ref.invalidate(cloudBooksProvider),
            ),
            data: (books) {
              // 已配置但清单失败 → 失败态（与「云端书库为空」区分）。
              if (books == null) {
                return _GuideView(
                  icon: Icons.error_outline,
                  title: '清单获取失败',
                  desc: '无法读取云端书目，请检查网络后重试',
                  actionLabel: '重试',
                  onAction: () => ref.invalidate(cloudBooksProvider),
                );
              }
              if (books.isEmpty) {
                return const _GuideView(
                  icon: Icons.cloud_queue_outlined,
                  title: '云端书库为空',
                  desc:
                      '云端还没有任何书籍。在书库导入并同步后，'
                      '书目会出现在这里。',
                );
              }
              return _LibraryView(
                books: books,
                localState: localAsync.value ?? const {},
                selected: _selected,
                rowBusy: _rowBusy,
                batchDone: _batchDone,
                batchTotal: _batchTotal,
                batchRunning: _batchRunning,
                onToggle: _toggle,
                onSelectAll: _selectAll,
                onRemoveOne: _removeOne,
                onRemoveSelected: _removeSelected,
              );
            },
          );
        },
      ),
    );
  }

  void _toggle(String bookId) {
    if (_busy) return;
    setState(() {
      if (!_selected.add(bookId)) _selected.remove(bookId);
    });
  }

  void _selectAll(List<CloudBookSummary> books) {
    if (_busy) return;
    setState(() {
      if (_selected.length == books.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(books.map((b) => b.bookId));
      }
    });
  }

  /// 行内「从云端移除」：单本调 [SyncFacade.removeFromCloud]（deleteMeta，
  /// 绝不走 deleteBook 的 tombstone 全局删除）；成功后刷新清单 + 轻提示。
  Future<void> _removeOne(CloudBookSummary book) async {
    if (_busy) return;
    setState(() => _rowBusy.add(book.bookId));
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(syncFacadeProvider).removeFromCloud(book.bookId);
    if (!mounted) return;
    setState(() => _rowBusy.remove(book.bookId));
    // 云端清单失效重取：drift 流驱动 books 表不受影响（本地行保留）。
    ref.invalidate(cloudBooksProvider);
    _selected.remove(book.bookId);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '《${book.title}》已从云端移除'
              : '《${book.title}》移除失败，请检查网络后重试',
        ),
      ),
    );
  }

  /// 批量「从云端移除」：逐本调 removeFromCloud（进度 x/y），结束出汇总。
  Future<void> _removeSelected() async {
    if (_busy || _selected.isEmpty) return;
    final targets = [
      for (final book
          in ref.read(cloudBooksProvider).value ?? const <CloudBookSummary>[])
        if (_selected.contains(book.bookId)) book,
    ];
    if (targets.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _batchRunning = true;
      _batchDone = 0;
      _batchTotal = targets.length;
    });
    var okCount = 0;
    final failures = <String>[];
    for (final book in targets) {
      final ok = await ref
          .read(syncFacadeProvider)
          .removeFromCloud(book.bookId);
      if (ok) {
        okCount++;
      } else {
        failures.add(book.title);
      }
      if (!mounted) return;
      setState(() => _batchDone++);
    }
    if (!mounted) return;
    setState(() {
      _batchRunning = false;
      _selected.clear();
    });
    ref.invalidate(cloudBooksProvider);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failures.isEmpty
              ? '已从云端移除 $okCount 本'
              : '移除完成：成功 $okCount 本，失败 ${failures.length} 本'
                    '（${failures.first}）',
        ),
      ),
    );
  }
}

// ── 状态视图 ────────────────────────────────────────────────────────────────

/// 引导 / 空态 / 失败态：图标 + 标题 + 说明（+ 动作按钮）。
class _GuideView extends StatelessWidget {
  const _GuideView({
    required this.icon,
    required this.title,
    required this.desc,
    this.actionLabel,
    this.onAction,
    this.route,
  });

  final IconData icon;
  final String title;
  final String desc;

  /// 动作按钮文案；非空时渲染按钮（[onAction] 直调或 [route] 跳转）。
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? route;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: t.text3),
              const SizedBox(height: AppSpacing.s3),
              Text(title, style: t.h3),
              const SizedBox(height: AppSpacing.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  desc,
                  style: t.sm.copyWith(color: t.text2),
                  textAlign: TextAlign.center,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: AppSpacing.s5),
                FilledButton(
                  onPressed:
                      onAction ??
                      (route == null ? null : () => context.go(route!)),
                  child: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 清单视图：info 说明条 + 清单卡（行列表 + 底部操作条）。
class _LibraryView extends StatelessWidget {
  const _LibraryView({
    required this.books,
    required this.localState,
    required this.selected,
    required this.rowBusy,
    required this.batchDone,
    required this.batchTotal,
    required this.batchRunning,
    required this.onToggle,
    required this.onSelectAll,
    required this.onRemoveOne,
    required this.onRemoveSelected,
  });

  final List<CloudBookSummary> books;

  /// bookId → 本地是否有正文（books 表比对；未取到时按仅云端显示）。
  final Map<String, bool> localState;
  final Set<String> selected;
  final Set<String> rowBusy;
  final int batchDone;
  final int batchTotal;
  final bool batchRunning;
  final void Function(String bookId) onToggle;
  final void Function(List<CloudBookSummary> books) onSelectAll;
  final Future<void> Function(CloudBookSummary book) onRemoveOne;
  final Future<void> Function() onRemoveSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final totalBytes = books.fold(0, (sum, b) => sum + b.sizeBytes);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部说明条（info 蓝底，§4.8 文案原型逐字）。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s6,
                AppSpacing.s4,
                AppSpacing.s6,
                0,
              ),
              child: _InfoNotice(
                text: TextSpan(
                  children: [
                    TextSpan(text: '「从云端移除」只删掉云端副本：'),
                    TextSpan(
                      text: '各端本地文件保留、照常可读',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(text: '，但也不会自动再传回云端。'),
                  ],
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s6,
                  AppSpacing.s4,
                  AppSpacing.s6,
                  AppSpacing.s3,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: t.surface,
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    border: Border.all(color: t.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 卡头：标题 + 「N 本 · 大小」胶囊（原型 card-head）。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.s5,
                          AppSpacing.s4,
                          AppSpacing.s5,
                          AppSpacing.s3,
                        ),
                        child: Row(
                          children: [
                            const Spacer(),
                            _CountPill(
                              text:
                                  '${books.length} 本 · '
                                  '${humanizeBytes(totalBytes)}',
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: t.border),
                      if (batchRunning)
                        LinearProgressIndicator(
                          value: batchTotal == 0
                              ? null
                              : batchDone / batchTotal,
                          minHeight: 3,
                        ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: books.length,
                          itemBuilder: (context, index) {
                            final book = books[index];
                            return _CloudBookTile(
                              book: book,
                              // 行键含 index：测试与复用定位稳定。
                              key: ValueKey('cloud-book-$index'),
                              downloaded: localState[book.bookId] ?? false,
                              selected: selected.contains(book.bookId),
                              busy: rowBusy.contains(book.bookId),
                              frozen: batchRunning,
                              onToggle: () => onToggle(book.bookId),
                              onRemove: () => onRemoveOne(book),
                            );
                          },
                        ),
                      ),
                      Divider(height: 1, color: t.border),
                      // 底部操作条（原型 bottom-bar）。
                      _BottomBar(
                        selectedCount: selected.length,
                        totalCount: books.length,
                        batchRunning: batchRunning,
                        batchDone: batchDone,
                        batchTotal: batchTotal,
                        onSelectAll: () => onSelectAll(books),
                        onRemoveSelected: onRemoveSelected,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// info 提示条（原型 .notice--info：infoSoft 底 + info 图标）。
class _InfoNotice extends StatelessWidget {
  const _InfoNotice({required this.text});

  final TextSpan text;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: t.infoSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: t.info),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text.rich(text, style: t.caption.copyWith(color: t.info)),
          ),
        ],
      ),
    );
  }
}

/// 数量胶囊（原型 .pill 中性小胶囊）。
class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: t.surface3,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Center(child: Text(text, style: t.micro.copyWith(fontSize: 11.5))),
    );
  }
}

/// 本地状态胶囊：`本地已下载`（中性）/ `仅云端`（info）。
class _LocalStatePill extends StatelessWidget {
  const _LocalStatePill({required this.downloaded});

  final bool downloaded;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final color = downloaded ? t.text2 : t.info;
    final bg = downloaded ? t.surface3 : t.infoSoft;
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Center(
        child: Text(
          downloaded ? '本地已下载' : '仅云端',
          style: t.micro.copyWith(fontSize: 11.5, color: color),
        ),
      ),
    );
  }
}

/// 清单行：勾选框 + 书名 + 格式·大小 + 本地状态胶囊 + 行内「从云端移除」。
class _CloudBookTile extends StatelessWidget {
  const _CloudBookTile({
    required this.book,
    required this.downloaded,
    required this.selected,
    required this.busy,
    required this.frozen,
    required this.onToggle,
    required this.onRemove,
    super.key,
  });

  final CloudBookSummary book;

  /// 本地是否有正文（books 表比对结果）。
  final bool downloaded;
  final bool selected;

  /// 本行移除进行中（按钮转圈）。
  final bool busy;

  /// 批量移除进行中（全页冻结勾选）。
  final bool frozen;
  final VoidCallback onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return InkWell(
      onTap: frozen ? null : onToggle,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s5,
          vertical: AppSpacing.s3,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.border)),
        ),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: frozen ? null : (_) => onToggle(),
            ),
            const SizedBox(width: AppSpacing.s2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: t.body.copyWith(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${book.format.toUpperCase()} · ${humanizeBytes(book.sizeBytes)}',
                    style: t.tertiary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            _LocalStatePill(downloaded: downloaded),
            const SizedBox(width: AppSpacing.s3),
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              // 原型 btn--outline btn--sm（中性描边小钮；危险色留给底部
              // 批量主操作 btn--danger）。
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.text,
                  side: BorderSide(color: t.border),
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: t.sm,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                onPressed: frozen ? null : onRemove,
                child: const Text('从云端移除'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 底部操作条：已选 n 项 + 全选 + 危险色「从云端移除」（批量）。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.selectedCount,
    required this.totalCount,
    required this.batchRunning,
    required this.batchDone,
    required this.batchTotal,
    required this.onSelectAll,
    required this.onRemoveSelected,
  });

  final int selectedCount;
  final int totalCount;
  final bool batchRunning;
  final int batchDone;
  final int batchTotal;
  final VoidCallback onSelectAll;
  final Future<void> Function() onRemoveSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s2,
        AppSpacing.s5,
        AppSpacing.s3,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              batchRunning
                  ? '正在移除（$batchDone / $batchTotal）…'
                  : selectedCount == 0
                  ? '未选择'
                  : '已选 $selectedCount 项',
              style: t.sm.copyWith(color: t.text2),
            ),
          ),
          TextButton(
            onPressed: batchRunning ? null : onSelectAll,
            child: Text(
              selectedCount == totalCount && totalCount > 0 ? '取消全选' : '全选',
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: t.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: batchRunning || selectedCount == 0
                ? null
                : onRemoveSelected,
            child: Text(batchRunning ? '移除中…' : '从云端移除'),
          ),
        ],
      ),
    );
  }
}
