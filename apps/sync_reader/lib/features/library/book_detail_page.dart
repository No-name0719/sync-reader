/// 书籍详情页（FR-104）：封面、元数据、进度与阅读时长统计，
/// 提供"打开阅读 / 重新选择文件（FR-410）/ 删除"操作；删除语义遵循
/// FR-408（softDelete + 游离文件）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/app_database.dart';
import '../../shared/cover_view.dart';
import '../../shared/format_utils.dart';
import '../sync/placeholder_download.dart';
import '../sync/sync_facade.dart' show syncFacadeProvider;
import 'library_providers.dart';
import 'replace/book_replace_service.dart';

/// 书籍详情页（`/book/:bookId`）。
class BookDetailPage extends ConsumerStatefulWidget {
  const BookDetailPage({super.key, required this.bookId});

  /// 目标书籍 ULID。
  final String bookId;

  @override
  ConsumerState<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends ConsumerState<BookDetailPage> {
  /// 文件替换进行中（FR-410 防重入：期间按钮禁用）。
  bool _replacing = false;

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    final bookAsync = ref.watch(bookDetailProvider(bookId));
    final progress = ref.watch(bookProgressProvider(bookId)).value;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('书籍详情'),
        actions: [
          if (bookAsync.value != null)
            IconButton(
              tooltip: '删除本书',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(bookAsync.value!),
            ),
        ],
      ),
      body: bookAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _MissingBook(error: error),
        data: (book) => book == null
            ? const _MissingBook()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 110,
                        height: 165,
                        child: CoverView(
                          coverPath: book.coverPath,
                          title: book.title,
                          author: book.author,
                          contentHash: book.contentHash,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              book.title,
                              style: theme.textTheme.headlineSmall,
                            ),
                            if (book.author.trim().isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                book.author,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Chip(
                                  label: Text(
                                    book.format.toUpperCase(),
                                    style: theme.textTheme.labelSmall,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                                if (book.localPath == null)
                                  const Chip(
                                    label: Text('仅云端'),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Divider(),
                  _metaRow(context, '文件名', book.fileName),
                  _metaRow(context, '大小', humanizeBytes(book.sizeBytes)),
                  _metaRow(context, '内容哈希', shortenHash(book.contentHash)),
                  _metaRow(context, '添加时间', formatEpochMs(book.addedAt)),
                  const Divider(),
                  _metaRow(
                    context,
                    '阅读进度',
                    progress == null
                        ? '尚未开始'
                        : '${formatPercent(progress.percent)}'
                              '（更新于 ${formatEpochMs(progress.updatedAt)}）',
                  ),
                  _metaRow(
                    context,
                    '上次阅读',
                    book.lastReadAt == null
                        ? '尚未阅读'
                        : formatEpochMs(book.lastReadAt),
                  ),
                  _metaRow(
                    context,
                    '累计阅读',
                    humanizeDuration(book.totalSeconds),
                  ),
                  const Divider(),
                  _metaToc(context, ref),
                  const SizedBox(height: 4),
                  Text(
                    '目录与章节跳转在阅读页内提供（顶部"打开"进入后查看）。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // 占位书（FR-402）：主按钮分流为"下载正文"，成功后直接
                  // 进阅读页；失败保持占位，可再次点击重试。
                  FilledButton.icon(
                    onPressed: book.localPath == null
                        ? () => unawaited(_downloadAndOpen(book))
                        : () => context.push('/reader/${book.bookId}'),
                    icon: Icon(
                      book.localPath == null
                          ? Icons.cloud_download_outlined
                          : Icons.menu_book_outlined,
                    ),
                    label: Text(
                      book.localPath == null
                          ? '下载正文'
                          : (progress == null || progress.percent <= 0)
                          ? '开始阅读'
                          : '继续阅读',
                    ),
                  ),
                  // 文件替换（FR-410）：仅本地有正文的书提供（占位书无文件
                  // 可替换）；进行中禁用防重入。
                  if (book.localPath != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _replacing
                          ? null
                          : () => unawaited(_startReplace(book)),
                      icon: const Icon(Icons.published_with_changes_outlined),
                      label: const Text('重新选择文件'),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  /// 元数据行：固定宽标签 + 内容。
  Widget _metaRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  /// 章节目录数量（FR-108 书库侧：仅展示数量，抽屉由阅读器负责）。
  Widget _metaToc(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              '章节目录',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: ref
                .watch(tocCountProvider(widget.bookId))
                .when(
                  data: (count) => Text(switch (count) {
                    null => '暂不可得（占位书或文件缺失）',
                    0 => '无章节结构',
                    _ => '共 $count 章',
                  }, style: theme.textTheme.bodyMedium),
                  loading: () => Text(
                    '解析中…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  error: (_, _) => Text('—', style: theme.textTheme.bodyMedium),
                ),
          ),
        ],
      ),
    );
  }

  /// 占位书下载（FR-402）：成功 → 详情刷新 + 直接进阅读页。
  Future<void> _downloadAndOpen(Book book) async {
    final ok = await downloadPlaceholderBook(
      context,
      ref,
      bookId: book.bookId,
      title: book.title,
    );
    if (!ok || !mounted) return;
    context.push('/reader/${book.bookId}');
  }

  /// 文件替换（FR-410）：确认对话框（语义警示）→ 选新文件 → 替换服务 →
  /// 结果反馈 + 详情刷新。用户取消任一步都静默返回，不动数据。
  Future<void> _startReplace(Book book) async {
    // 未配置同步（异常按未配置）→ 对话框追加"仅替换本地"说明。
    bool syncConfigured;
    try {
      syncConfigured = await ref.read(syncFacadeProvider).readConfig() != null;
    } catch (_) {
      syncConfigured = false; // 安全存储不可用：按未配置（对齐占位书下载）。
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('替换《${book.title}》的正文文件？'),
        content: Text(
          '· 新文件将替换本书正文，云端与其他设备的正文在下次同步后更新；\n'
          '· 阅读进度保留，其他设备会按大致位置（百分比）恢复。'
          '${syncConfigured ? '' : '\n· 当前未配置同步，仅替换本地文件。'}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('选择新文件'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // 选新文件（扩展名已按注册格式过滤）；取消静默返回。
    final sourcePath = await ref.read(replaceFilePickerProvider).pickBookFile();
    if (sourcePath == null || !mounted) return;

    final bookId = widget.bookId;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _replacing = true);
    final progress = messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 10),
        content: Text('正在替换《${book.title}》…'),
      ),
    );
    try {
      final result = await ref
          .read(bookReplaceServiceProvider)
          .replaceFile(bookId: bookId, sourcePath: sourcePath);
      progress.close();
      if (mounted) {
        // 成功/失败都失效一次性详情 provider（列表/进度走 drift watch 自动刷新）。
        ref.invalidate(bookDetailProvider);
        messenger.showSnackBar(
          SnackBar(
            content: Text(result.toMessage()),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _replacing = false);
    }
  }

  /// 删除确认（FR-408 语义说明）→ softDelete + moveToOrphans → 返回书库。
  Future<void> _confirmDelete(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除《${book.title}》？'),
        content: const Text(
          '删除后的行为：\n'
          '· 本地书目与阅读进度移入库内回收区；\n'
          '· 正文文件移入游离区保留，可手动恢复或清理；\n'
          '· 删除标记（tombstone）将同步到云端，其他设备的此书'
          '也会移出书库（其正文文件同样保留）。\n\n'
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
    await store.moveToOrphans(book.bookId);
    await ref.read(booksDaoProvider).softDelete(book.bookId);
    // 云端 tombstone 推送（FR-408）：本地优先之后台进行，不阻塞返回书库；
    // 失败由引擎记入 tombstone 账本，下次全量同步补推收敛。
    unawaited(ref.read(syncFacadeProvider).deleteBook(book.bookId));
    if (mounted) context.go('/');
  }
}

/// 书籍不存在或已删除的空态。
class _MissingBook extends StatelessWidget {
  const _MissingBook({this.error});

  /// 数据层异常（与"记录不存在"区分展示）。
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            error == null ? '书籍不存在或已删除' : '书籍信息加载失败：$error',
            style: theme.textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () => context.go('/'),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回书库'),
          ),
        ],
      ),
    );
  }
}
