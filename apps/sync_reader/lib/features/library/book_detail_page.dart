/// 书籍详情页（FR-104 / v1.1 A7，docs/10 §4.3）：按原型重排为四区块——
/// Hero（大封面 + 书名/作者/标签 + 进度条 + 主操作）、「阅读数据」卡
/// （4 统计块 + 近 7 天阅读量柱状图，FR-208）、「文件信息」卡（定义列表）、
/// 「目录」卡（新增目录预览）。提供"打开阅读 / 重新选择文件（FR-410）/
/// 删除"操作；删除语义遵循 FR-408（docs/10 §4.7b，2026-11-18 变更）：
/// 删正文文件 + 移出书库 + 写墓碑。
library;

import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/design_tokens.dart';
import '../../data/db/app_database.dart';
import '../../shared/copy.dart';
import '../../shared/cover_view.dart';
import '../../shared/format_utils.dart';
import '../reader/contract/book_file.dart';
import '../reader/contract/progress_anchor.dart';
import '../reader/contract/toc_entry.dart';
import '../sync/placeholder_download.dart';
import '../sync/sync_facade.dart' show syncFacadeProvider;
import 'library_filters.dart';
import 'library_providers.dart';
import 'replace/book_replace_service.dart';
import 'widgets/book_cards.dart' show kCoverAspectRatio;

/// 目录预览（v1.1 A7 新增）：**复用阅读器既有解析管线**
/// （`FormatRegistry` → handler.`parseMetadata`，基类保证解析失败不抛出、
/// 降级为空目录），不为预览另写解析器。
///
/// - 返回 null = 无法给出（占位书 / 无 handler / 正文文件丢失）；
/// - 返回空列表 = 解析成功但无目录结构（txt 章节切分失败等）→ UI 优雅降级。
/// 解析异步进行（FutureBuilder / AsyncValue 消费），不阻塞首帧。
final bookTocPreviewProvider = FutureProvider.family<List<TocEntry>?, String>((
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
    return (await handler.parseMetadata(file)).toc;
  } catch (_) {
    // 正文文件丢失（如已被移除）→ 无法给出。
    return null;
  }
});

/// locator JSON → 「第 N 章」（1 起）；取不到返回 null（UI 只显示百分比）。
///
/// 各格式 handler 的目录与位置坐标一一对应（0 起）：txt = `chapterIndex`
/// （章表逐章生成目录）、md = `headingIndex`（标题块序数）、epub =
/// `spineIndex`（spine 逐项生成目录），因此 +1 即章序；pdf 只有 `pageIndex`
/// 等无章节语义的坐标 → 取不到。只做 JSON 解码（契约层 [ProgressAnchor]），
/// 不触碰各格式的 locator 实现。纯函数，可测。
int? locatorChapterNumber(String? locatorJson) {
  if (locatorJson == null || locatorJson.isEmpty) return null;
  final map = ProgressAnchor.fromRaw(locatorJson, 0).decodeLocator();
  if (map == null) return null;
  for (final key in const ['chapterIndex', 'headingIndex', 'spineIndex']) {
    final value = map[key];
    if (value is int && value >= 0) return value + 1;
  }
  return null;
}

/// 目录预览最多展示的条数（超出给「在阅读器内查看完整目录」提示）。
const int _kTocPreviewLimit = 20;

/// 近 7 天柱状图的单柱最大高度（原型 `.spark` height: 56px）。
const double _kSparkMaxBarHeight = 56;

/// 柱的最小可见高度（原型 `Math.max(3, …)`：无数据日画 3px 零高柱）。
const double _kSparkMinBarHeight = 3;

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

  /// 最近 7 天按天阅读记录（FR-208）：页面进入取一次即可（本地查询，
  /// 不必 watch 实时刷新）；day DESC，图表侧再翻转并补缺口日。
  late final Future<List<ReadingDay>> _readingDaysFuture = _loadReadingDays();

  /// 拉取按天记录：最近 7 条（day DESC 已排序）。失败向上抛给
  /// FutureBuilder 静默降级空态，不影响页面其余部分。
  Future<List<ReadingDay>> _loadReadingDays() async =>
      (await ref.read(readingDaysDaoProvider).daysByBook(widget.bookId))
          .take(7)
          .toList(growable: false);

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    final bookAsync = ref.watch(bookDetailProvider(bookId));
    final progress = ref.watch(bookProgressProvider(bookId)).value;

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
            : LayoutBuilder(
                builder: (context, constraints) {
                  // 原型 ≤700px：Hero 折为纵向、封面 128px、书名降为 h1。
                  final narrow = constraints.maxWidth < 700;
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppLayout.contentMaxWidth,
                      ),
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.s6),
                        children: [
                          _Hero(
                            book: book,
                            progress: progress,
                            narrow: narrow,
                            replacing: _replacing,
                            onPrimary: book.localPath == null
                                ? () => unawaited(_downloadAndOpen(book))
                                : () => context.push('/reader/${book.bookId}'),
                            onReplace: book.localPath == null
                                ? null
                                : () => unawaited(_startReplace(book)),
                          ),
                          _StatsCard(
                            book: book,
                            progress: progress,
                            readingDaysFuture: _readingDaysFuture,
                          ),
                          _FileCard(book: book),
                          _TocCard(bookId: bookId, progress: progress),
                        ],
                      ),
                    ),
                  );
                },
              ),
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
          syncConfigured
              ? '新文件将替换本书正文，阅读进度保留；云端与其他设备在下次同步后更新。'
              : '新文件将替换本书正文，阅读进度保留；当前未配置同步，仅替换本地文件。',
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

  /// 删除确认（FR-408 删除语义，docs/10 §4.7b）→ 移出书库（删正文、
  /// 删 books 行 + 写墓碑）→ 推 tombstone → 返回书库。
  Future<void> _confirmDelete(Book book) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(deleteBookDialogTitle(book.title)),
        content: const Text(kDeleteBookDialogBody),
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
    // 删除语义（docs/10 §4.7b）：删正文/封面文件 + 移出书库（books 行
    // 删除 → 书库里不再出现）+ 写墓碑；进度行随之级联清除。
    await ref
        .read(booksDaoProvider)
        .deleteBook(book.bookId, removeFiles: store.deleteBookFiles);
    // 云端 tombstone 推送（FR-408）：本地优先之后台进行，不阻塞返回书库；
    // 失败由引擎记入 tombstone 账本，下次全量同步补推收敛。
    unawaited(ref.read(syncFacadeProvider).deleteBook(book.bookId));
    if (mounted) context.go('/');
  }
}

// ===========================================================================
// Hero 区（原型 .detail-hero）
// ===========================================================================

/// Hero：大封面（168px，t.sh3 阴影）+ 右侧标题/作者/标签/进度条/主操作。
class _Hero extends ConsumerWidget {
  const _Hero({
    required this.book,
    required this.progress,
    required this.narrow,
    required this.replacing,
    required this.onPrimary,
    this.onReplace,
  });

  final Book book;
  final BookProgress? progress;

  /// 窄屏（<700px）：纵向布局、封面 128px、书名 h1。
  final bool narrow;

  /// 文件替换进行中（FR-410 防重入：期间按钮禁用）。
  final bool replacing;

  /// 主操作（继续阅读 / 开始阅读 / 下载正文，由占位与否分流）。
  final VoidCallback onPrimary;

  /// 文件替换（FR-410）：仅本地有正文的书提供；null = 不显示。
  final VoidCallback? onReplace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    // 局部变量：成员字段不参与空安全类型提升。
    final progress = this.progress;
    // 同步状态（docs/10 §4.2 四态语义，与书库一致）；流未就绪按空集合近似。
    final bucket = classifyBookStatus(
      book,
      localOnlyIds: ref.watch(localOnlyIdsProvider).value ?? const <String>{},
      cloudBaseIds: ref.watch(cloudBaseIdsProvider).value ?? const <String>{},
      cloudMissingMarks: ref.watch(cloudMissingMarksProvider),
    );

    final cover = Container(
      width: narrow ? 128 : 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: t.sh3,
      ),
      child: AspectRatio(
        aspectRatio: kCoverAspectRatio,
        child: CoverView(
          coverPath: book.coverPath,
          title: book.title,
          author: book.author,
          contentHash: book.contentHash,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    );

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 书名（display 30px；窄屏 h1 22px，对齐原型媒体查询）。
        Text(
          book.title,
          maxLines: narrow ? 3 : 2,
          overflow: TextOverflow.ellipsis,
          style: narrow
              ? t.h1
              : t.display.copyWith(
                  letterSpacing: -0.02 * AppTextScale.display.fontSize,
                ),
        ),
        if (book.author.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(book.author, style: t.body.copyWith(color: t.text2)),
        ],
        const SizedBox(height: AppSpacing.s3),
        Wrap(
          spacing: AppSpacing.s2,
          runSpacing: AppSpacing.s2,
          children: [
            _Pill.brand(book.format.toUpperCase()),
            switch (bucket) {
              LibraryStatusBucket.synced => const _Pill.neutral('已同步'),
              LibraryStatusBucket.localOnly => const _Pill.brand('仅本地'),
              LibraryStatusBucket.cloudOnly => const _Pill.warn('仅云端'),
            },
          ],
        ),
        const SizedBox(height: AppSpacing.s4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: _progressBlock(context),
        ),
        // 主操作按钮组（原型 .actions）：继续阅读·主按钮 + 重新选择文件；
        // 占位书主按钮分流为「下载正文」（FR-402）。删除保持在 AppBar
        // （图标按钮），避免与确认弹窗的「删除」按钮产生同名歧义。
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s5),
          child: Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              FilledButton.icon(
                onPressed: onPrimary,
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
              if (onReplace != null)
                OutlinedButton.icon(
                  onPressed: replacing ? null : onReplace,
                  icon: const Icon(Icons.published_with_changes_outlined),
                  label: const Text('重新选择文件'),
                ),
            ],
          ),
        ),
      ],
    );

    // 原型：桌面左右排布（gap s6），≤700px 纵向（gap s4）。
    final Widget layout;
    if (narrow) {
      layout = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cover,
          const SizedBox(height: AppSpacing.s4),
          info,
        ],
      );
    } else {
      layout = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cover,
          const SizedBox(width: AppSpacing.s6),
          Expanded(child: info),
        ],
      );
    }
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s6),
      padding: const EdgeInsets.only(bottom: AppSpacing.s6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: layout,
    );
  }

  /// 进度块（原型：`阅读进度` 标签行 + 6px 品牌色进度条）。
  Widget _progressBlock(BuildContext context) {
    final t = context.appTokens;
    // 局部变量：成员字段不参与空安全类型提升。
    final progress = this.progress;
    final percent = progress?.percent ?? 0;
    final chapter = progress == null
        ? null
        : locatorChapterNumber(progress.locatorJson);
    final percentText = progress == null ? '未读' : formatPercent(percent);
    // locator 无章节语义坐标（pdf / 空 locator）时只显示百分比。
    final valueText = chapter == null
        ? percentText
        : '$percentText · 第 $chapter 章';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('阅读进度', style: t.caption.copyWith(color: t.text3)),
            const Spacer(),
            Text(
              valueText,
              key: const Key('detail_progress_text'),
              style: t.caption.copyWith(
                color: t.text,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.full),
          child: Container(
            height: 6,
            color: t.surface3,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              key: const Key('detail_progress_fill'),
              widthFactor: percent.clamp(0.0, 1.0),
              child: Container(color: t.brand),
            ),
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// 通用小件
// ===========================================================================

/// 胶囊（原型 `.pill` / `.pill--brand` / `.pill--warn`）：高 22、圆角全、
/// micro 字阶（11px/600）。
class _Pill extends StatelessWidget {
  const _Pill.brand(this.label) : _kind = _PillKind.brand;

  const _Pill.neutral(this.label) : _kind = _PillKind.neutral;

  const _Pill.warn(this.label) : _kind = _PillKind.warn;

  final String label;
  final _PillKind _kind;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final (Color bg, Color fg) = switch (_kind) {
      _PillKind.brand => (t.brandSoft, t.brandText),
      _PillKind.neutral => (t.surface3, t.text2),
      _PillKind.warn => (t.warnSoft, t.warn),
    };
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(label, style: t.micro.copyWith(color: fg)),
    );
  }
}

enum _PillKind { brand, neutral, warn }

/// 区块卡片（原型 `.card`）：t.surface + 1px t.border + AppRadius.lg +
/// t.sh1；头部 = 标题（h2）+ 可选尾饰，1px 分隔线，内容区 s4/s5 内边距。
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, this.trailing, required this.child});

  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.s4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
        boxShadow: t.sh1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s4,
              AppSpacing.s5,
              AppSpacing.s4,
            ),
            child: Row(
              children: [
                Text(title, style: t.h2),
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: t.border),
          Padding(padding: const EdgeInsets.all(AppSpacing.s5), child: child),
        ],
      ),
    );
  }
}

// ===========================================================================
// 「阅读数据」卡（原型 .detail-stats + .spark）
// ===========================================================================

/// 4 个统计块 + 近 7 天阅读量柱状图（FR-208）。
class _StatsCard extends ConsumerWidget {
  const _StatsCard({
    required this.book,
    required this.progress,
    required this.readingDaysFuture,
  });

  final Book book;
  final BookProgress? progress;

  /// 按天记录（day DESC，最多 7 条）；加载中不占位，失败静默降级空态。
  final Future<List<ReadingDay>> readingDaysFuture;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 章节数复用目录预览 provider（同一份解析结果，不重复解析）。
    final tocCount = ref
        .watch(bookTocPreviewProvider(book.bookId))
        .value
        ?.length;
    return _SectionCard(
      title: '阅读数据',
      trailing: const _Pill.neutral('最近 7 天'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              // 原型 auto-fit minmax(150px, 1fr)：按可用宽估算列数。
              final columns = (constraints.maxWidth / 166).floor().clamp(1, 4);
              return _statGrid(context, tocCount, columns);
            },
          ),
          const SizedBox(height: AppSpacing.s3),
          FutureBuilder<List<ReadingDay>>(
            future: readingDaysFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const SizedBox.shrink();
              }
              final recent = snapshot.data;
              if (recent == null || recent.isEmpty) {
                return Text(
                  '暂无按天记录',
                  style: context.appTokens.caption.copyWith(
                    color: context.appTokens.text3,
                  ),
                );
              }
              return _spark(context, recent);
            },
          ),
        ],
      ),
    );
  }

  /// 统计块网格（阅读进度 / 累计阅读 / 上次阅读 / 章节，对齐原型四块；
  /// 数据取得到什么用什么，取不到显示 —）。
  Widget _statGrid(BuildContext context, int? tocCount, int columns) {
    final items = <(String, String, double)>[
      ('阅读进度', progress == null ? '—' : formatPercent(progress!.percent), 17),
      ('累计阅读', humanizeDuration(book.totalSeconds), 17),
      // 全时间串较长：缩字号（原型该块亦降到 14px）。
      (
        '上次阅读',
        (book.lastReadAt ?? 0) <= 0 ? '—' : formatEpochMs(book.lastReadAt),
        14,
      ),
      ('章节', tocCount == null ? '—' : '$tocCount', 17),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < items.length; i += columns) ...[
          if (i > 0) const SizedBox(height: AppSpacing.s3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var j = i; j < i + columns && j < items.length; j++) ...[
                if (j > i) const SizedBox(width: AppSpacing.s3),
                Expanded(child: _stat(context, items[j])),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// 单个统计块（原型 `.stat`：surface-2 底 + 1px 描边 + 圆角 md）。
  Widget _stat(BuildContext context, (String, String, double) item) {
    final t = context.appTokens;
    final (label, value, valueSize) = item;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: t.caption.copyWith(color: t.text3)),
          const SizedBox(height: 2),
          // 长串（如 2026-10-26 09:30）在窄块内缩放不溢出。
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: valueSize,
                height: 1.3,
                fontWeight: FontWeight.w600,
                color: t.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 近 7 天阅读量柱状图（原型 `.spark` / `.spark-x`）：
  /// 窗口 = 以最近一条记录的自然日为终点回溯 7 个自然日；缺口日（没读）
  /// 画零高柱（3px 最小可见高度）；最高柱用品牌色高亮（原型 `.is-hi`）。
  Widget _spark(BuildContext context, List<ReadingDay> recentDesc) {
    final t = context.appTokens;
    final byDay = {for (final d in recentDesc) d.day: d.seconds};
    // 窗口终点不取「今天」而取最近记录日：今天没读时图形不整体塌成零柱，
    // 且注入数据可测（不依赖真实时钟；取舍见交付说明）。
    final end = DateTime.parse(recentDesc.first.day);
    final window = <(String, int)>[
      for (var i = 6; i >= 0; i--)
        () {
          final d = DateTime(end.year, end.month, end.day - i);
          final key =
              '${d.year.toString().padLeft(4, '0')}-'
              '${d.month.toString().padLeft(2, '0')}-'
              '${d.day.toString().padLeft(2, '0')}';
          return (key, byDay[key] ?? 0);
        }(),
    ];
    final maxSeconds = window.fold(0, (m, d) => max(m, d.$2));

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: _kSparkMaxBarHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (day, seconds) in window)
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        key: Key('detail_spark_bar_$day'),
                        height: maxSeconds <= 0
                            ? _kSparkMinBarHeight
                            : (seconds / maxSeconds * _kSparkMaxBarHeight)
                                  .clamp(
                                    _kSparkMinBarHeight,
                                    _kSparkMaxBarHeight,
                                  ),
                        decoration: BoxDecoration(
                          // 最高柱品牌色（并列取全部），其余品牌浅底。
                          color: maxSeconds > 0 && seconds == maxSeconds
                              ? t.brand
                              : t.brandSoft2,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              for (final (day, _) in window)
                Expanded(
                  child: Text(
                    day.substring(5),
                    textAlign: TextAlign.center,
                    style: t.micro.copyWith(color: t.text3),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ===========================================================================
// 「文件信息」卡（原型 .dl）
// ===========================================================================

/// 定义列表：文件名 / 大小 / 哈希（截断可复制）/ 添加时间 / 同步状态。
class _FileCard extends ConsumerWidget {
  const _FileCard({required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 同步状态（四态语义与书库一致，docs/10 §4.2）；流未就绪按空集合近似。
    final bucket = classifyBookStatus(
      book,
      localOnlyIds: ref.watch(localOnlyIdsProvider).value ?? const <String>{},
      cloudBaseIds: ref.watch(cloudBaseIdsProvider).value ?? const <String>{},
      cloudMissingMarks: ref.watch(cloudMissingMarksProvider),
    );
    final syncText = switch (bucket) {
      LibraryStatusBucket.synced => '已同步',
      LibraryStatusBucket.localOnly => '仅本地',
      // 与 Hero 标签「仅云端」措辞区分，避免同名文案重复。
      LibraryStatusBucket.cloudOnly => '未下载（仅云端）',
    };
    return _SectionCard(
      title: '文件信息',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _dlRow(context, '文件名', _dlText(context, book.fileName)),
          _dlRow(
            context,
            '大小',
            _dlText(context, humanizeBytes(book.sizeBytes)),
          ),
          _dlRow(context, '内容哈希', _hashValue(context)),
          _dlRow(
            context,
            '添加时间',
            _dlText(context, formatEpochMs(book.addedAt)),
          ),
          _dlRow(context, '同步状态', _dlText(context, syncText)),
        ],
      ),
    );
  }

  /// 哈希行：截断展示 + 一键复制（复制完整 `sha256:<hex>`）。
  Widget _hashValue(BuildContext context) {
    final t = context.appTokens;
    return Row(
      children: [
        Expanded(
          child: SelectableText(
            shortenHash(book.contentHash),
            style: t.sm.copyWith(color: t.text),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            tooltip: '复制内容哈希',
            padding: EdgeInsets.zero,
            iconSize: 16,
            icon: const Icon(Icons.copy_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: book.contentHash));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('内容哈希已复制'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 定义列表行（原型 `.dl`：108px 标签列 + 1fr 内容列，13px）。
  Widget _dlRow(BuildContext context, String label, Widget value) {
    final t = context.appTokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label, style: t.sm.copyWith(color: t.text3)),
          ),
          Expanded(child: value),
        ],
      ),
    );
  }

  Widget _dlText(BuildContext context, String value) {
    final t = context.appTokens;
    return Text(value, style: t.sm.copyWith(color: t.text));
  }
}

// ===========================================================================
// 「目录」卡（v1.1 A7 新增目录预览）
// ===========================================================================

/// 目录预览：前 20 条按层级缩进，当前章高亮（locator 可定位时）；超出提示
/// 「在阅读器内查看完整目录」；解析失败 / 无目录优雅降级。
class _TocCard extends ConsumerWidget {
  const _TocCard({required this.bookId, required this.progress});

  final String bookId;
  final BookProgress? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    // 局部变量：成员字段不参与空安全类型提升。
    final progress = this.progress;
    final tocAsync = ref.watch(bookTocPreviewProvider(bookId));
    final entries = tocAsync.value;
    // locator 的章节坐标（0 起）即目录条目序（各 handler 目录 1:1 生成，
    // 见 [locatorChapterNumber]）；越界/无进度则不高亮。
    final currentIndex = progress == null
        ? null
        : (locatorChapterNumber(progress.locatorJson) ?? 0) - 1;
    final Widget body = tocAsync.when(
      loading: () => Text('解析中…', style: t.sm.copyWith(color: t.text3)),
      error: (_, _) => Text(
        // provider 内已兜底，理论上不触达。
        kTocUnavailableText,
        style: t.sm.copyWith(color: t.text3),
      ),
      data: (entries) {
        if (entries == null) {
          return Text(kTocUnavailableText, style: t.sm.copyWith(color: t.text3));
        }
        if (entries.isEmpty) {
          // txt 章节切分失败等 → 优雅降级。
          return Text('无目录信息', style: t.sm.copyWith(color: t.text3));
        }
        final visible = entries.take(_kTocPreviewLimit).toList(growable: false);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < visible.length; i++)
              _tocItem(context, visible[i], i, i == currentIndex),
            if (entries.length > _kTocPreviewLimit)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.s2),
                child: Text(
                  '在阅读器内查看完整目录',
                  style: t.caption.copyWith(color: t.text3),
                ),
              ),
          ],
        );
      },
    );
    return _SectionCard(
      title: '目录',
      trailing: entries == null || entries.isEmpty
          ? null
          : _Pill.neutral('共 ${entries.length} 章'),
      child: body,
    );
  }

  /// 目录条目行（原型 `.toc-item`：层级缩进 s3/s5/s8，当前章品牌浅底 +
  /// 「当前」胶囊）。
  Widget _tocItem(
    BuildContext context,
    TocEntry entry,
    int index,
    bool current,
  ) {
    final t = context.appTokens;
    final leftPad = switch (entry.level) {
      0 => AppSpacing.s3,
      1 => AppSpacing.s5,
      _ => AppSpacing.s8,
    };
    return Container(
      key: Key('detail_toc_item_$index'),
      padding: EdgeInsets.fromLTRB(leftPad, 9, AppSpacing.s3, 9),
      decoration: BoxDecoration(
        color: current ? t.brandSoft : null,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.sm.copyWith(
                color: current ? t.brandText : t.text,
                fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          if (current) ...[
            const SizedBox(width: AppSpacing.s2),
            const _Pill.brand('当前'),
          ],
        ],
      ),
    );
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
