/// 书库条目卡片（FR-105 / v1.1 A5+A20）：网格卡片与列表磁贴。
///
/// v1.1 交互（Q15）：点封面直接打开书（无 hover 浮层按钮，hover 仅视觉
/// 上浮）；信息入口 = 桌面右键 / 触屏长按的上下文菜单（由页面提供
/// [onContextMenu]，菜单项按状态裁剪）；进度与状态收进封面右上角胶囊，
/// 取代旧版底部黑色百分比遮条（进度改为封面下沿 3px 品牌色进度条）。
/// 卡片不直接触碰同步引擎：状态值由书库页从 provider 传入。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/design_tokens.dart';
import '../../../data/db/app_database.dart';
import '../../../shared/cover_view.dart';
import '../../../shared/format_utils.dart';
import '../../sync/sync_status.dart';
import '../library_grid_metrics.dart';

/// 封面宽高比（书籍标准 2:3，原型 `.book-cover` aspect-ratio）。
///
/// 与网格宽屏档共用同一常量（唯一度量来源，见 `library_grid_metrics.dart`），
/// 避免「详情页封面」与「书架网格」的比例各写一份而走样。
const double kCoverAspectRatio = libraryGridComfortableCoverAspect;

/// 封面右上角状态胶囊种类（优先级从高到低，A5/A20）。
enum CoverBadgeKind {
  /// 最近一轮同步该书记录了错误（danger）。
  syncFailed,

  /// progress.dirty（warn）。
  pendingUpload,

  /// 仅本地（brand-soft 底 brand-text 字）。
  localOnly,

  /// 未下载（仅云端占位书；墨色胶囊）。
  notDownloaded,

  /// 阅读百分比（brand 胶囊白字）。
  percent,
}

/// 状态胶囊判定（纯函数，可测）。
///
/// 优先级：同步失败 > 待上传 > 仅本地 > 未下载 > 百分比（docs/10 §4.2）。
/// [syncStatus] 来自 `bookSyncStatusMapProvider`：error 项即「该书在最近
/// 一轮同步 report 里失败」；取不到（provider 未就绪）时该条自动让位。
CoverBadgeKind? coverBadgeFor({
  required Book book,
  required bool localOnly,
  BookSyncStatus? syncStatus,
  double? percent,
}) {
  if (syncStatus == BookSyncStatus.error) return CoverBadgeKind.syncFailed;
  if (syncStatus == BookSyncStatus.pendingUpload) {
    return CoverBadgeKind.pendingUpload;
  }
  if (localOnly) return CoverBadgeKind.localOnly;
  if ((book.localPath ?? '').isEmpty) return CoverBadgeKind.notDownloaded;
  if (percent != null) return CoverBadgeKind.percent;
  return null;
}

/// 封面右上角状态胶囊（原型 `.cover-badge`：高 21、圆角全、11px/650）。
class CoverBadge extends StatelessWidget {
  const CoverBadge({super.key, required this.kind, this.percent});

  final CoverBadgeKind kind;

  /// 阅读比例（仅 [CoverBadgeKind.percent] 使用）。
  final double? percent;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final (Color bg, Color fg, String label) = switch (kind) {
      CoverBadgeKind.syncFailed => (
        t.danger.withValues(alpha: 0.92),
        t.isDark ? const Color(0xFF2A0F0C) : Colors.white,
        '同步失败',
      ),
      CoverBadgeKind.pendingUpload => (
        t.warn.withValues(alpha: 0.92),
        t.isDark ? const Color(0xFF2A1503) : Colors.white,
        '待上传',
      ),
      CoverBadgeKind.localOnly => (t.brandSoft, t.brandText, '仅本地'),
      // 墨色胶囊（原型 rgba(40,37,32,0.82) / #f6f1e5，两套主题均可读）。
      CoverBadgeKind.notDownloaded => (
        const Color(0xCC282520),
        const Color(0xFFF6F1E5),
        '未下载',
      ),
      CoverBadgeKind.percent => (
        t.brand,
        t.isDark ? const Color(0xFF06231F) : Colors.white,
        formatPercent(percent ?? 0),
      ),
    };
    return Container(
      height: 21,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 封面下沿 3px 品牌色进度条（有进度时；取代旧版黑色百分比遮条）。
class CoverProgressBar extends StatelessWidget {
  const CoverProgressBar({
    super.key,
    required this.percent,
    this.onPaper = false,
  });

  /// 阅读比例 0.0–1.0。
  final double percent;

  /// 纸底生成封面上用深色轨（原型 `.book-cover.paper .cover-progress`），
  /// 真封面（照片）上用白色半透明轨。
  final bool onPaper;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final track = onPaper
        ? Colors.black.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.3);
    return Container(
      height: 3,
      color: track,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: percent.clamp(0.0, 1.0),
        child: Container(color: t.brand),
      ),
    );
  }
}

/// 触屏长按手势（A20）：长按弹上下文菜单。显式排除鼠标——桌面长按属于
/// 拖拽归组（FR-107），菜单走右键；两者在竞技场上互不竞争。
class TouchLongPressMenu extends StatelessWidget {
  const TouchLongPressMenu({
    super.key,
    required this.onMenu,
    required this.child,
  });

  /// 触屏长按回调（参数为菜单锚点的全局坐标）。
  final void Function(Offset globalPosition) onMenu;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: {
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                // 仅触屏/笔：鼠标长按留给拖拽归组（FR-107 × A20 冲突解法）。
                supportedDevices: const {
                  PointerDeviceKind.touch,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              (instance) {
                instance.onLongPressStart = (details) =>
                    onMenu(details.globalPosition);
              },
            ),
      },
      child: child,
    );
  }
}

/// 网格卡片（A5/A20）：封面（圆角 10 + 轻投影 + hover 上浮 3px）+ 右上角
/// 状态胶囊 + 下沿进度条 + 书名/作者/时长三行（Q7）。
///
/// [compact] = 窄屏（手机）紧凑卡：书名叠在封面底部（渐变遮罩保证可读），
/// 不再另起文字区 —— 手机一屏因此能放下 3 行完整卡片（v1.3.4 密度整改）。
class BookGridCard extends StatelessWidget {
  const BookGridCard({
    super.key,
    required this.book,
    this.percent,
    this.syncStatus,
    this.localOnly = false,
    this.onOpen,
    this.onContextMenu,
    this.compact = false,
    this.coverAspectRatio = kCoverAspectRatio,
  });

  final Book book;

  /// 阅读比例 0.0–1.0（null = 尚未阅读）。
  final double? percent;

  /// 每书同步状态（null = 「同步失败/待上传」条目自动让位）。
  final BookSyncStatus? syncStatus;

  /// 是否「仅本地」（docs/10 §4.7c）。
  final bool localOnly;

  /// 点封面直接打开书（分流在页面：有正文进阅读器，未下载先下载）。
  final VoidCallback? onOpen;

  /// 右键 / 触屏长按的上下文菜单回调（全局坐标）。
  final void Function(Offset globalPosition)? onContextMenu;

  /// 紧凑卡（窄屏）：书名叠在封面底部，卡高 = 封面高。
  final bool compact;

  /// 封面宽高比（宽/高）。宽屏固定 2:3；窄屏由网格度量按可见行数自适应。
  final double coverAspectRatio;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final badgeKind = coverBadgeFor(
      book: book,
      localOnly: localOnly,
      syncStatus: syncStatus,
      percent: percent,
    );
    final paper = (book.coverPath ?? '').isEmpty;
    final hasProgress = percent != null && percent! > 0;

    final cover = AspectRatio(
      aspectRatio: coverAspectRatio,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          boxShadow: t.sh2,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: CoverView(
                coverPath: book.coverPath,
                title: book.title,
                author: book.author,
                contentHash: book.contentHash,
                borderRadius: BorderRadius.circular(AppRadius.md),
                // 紧凑卡的书名由卡片自己叠在封面上，纸底封面不再重复排一遍。
                showTextBlock: !compact,
              ),
            ),
            if (badgeKind != null)
              Positioned(
                top: 8,
                right: 8,
                child: CoverBadge(kind: badgeKind, percent: percent),
              ),
            if (hasProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: CoverProgressBar(percent: percent!, onPaper: paper),
              ),
            if (compact)
              _CompactTitleOverlay(book: book, hasProgress: hasProgress),
          ],
        ),
      ),
    );

    return TouchLongPressMenu(
      onMenu: (pos) => onContextMenu?.call(pos),
      child: GestureDetector(
        // 桌面右键 → 上下文菜单（触屏走上面的长按）。
        onSecondaryTapUp: (details) =>
            onContextMenu?.call(details.globalPosition),
        child: _HoverLift(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: onOpen,
            child: compact
                ? cover
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      cover,
                      const SizedBox(height: AppSpacing.s1),
                      // 书名：h3 加粗，最多两行（预留两行高度防网格溢出，Q7）。
                      SizedBox(
                        height: 36,
                        child: Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.h3.copyWith(fontSize: 13.5, height: 1.3),
                        ),
                      ),
                      if (book.author.trim().isNotEmpty)
                        Text(
                          book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.caption.copyWith(color: t.text2),
                        ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(Icons.schedule, size: 12, color: t.text3),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              book.totalSeconds > 0
                                  ? humanizeDuration(book.totalSeconds)
                                  : '未读',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.tertiary.copyWith(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 紧凑卡的书名叠加层：封面底部渐变遮罩 + 白色单行书名。
///
/// 遮罩从透明渐变到墨色，保证浅色纸底封面与深色照片封面上书名都可读；
/// 底部为封面下沿的进度条留出位置（[hasProgress]）。
class _CompactTitleOverlay extends StatelessWidget {
  const _CompactTitleOverlay({required this.book, required this.hasProgress});

  final Book book;

  /// 封面下沿是否有进度条（要给它让位）。
  final bool hasProgress;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xCC000000)],
            stops: [0, 1],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s2,
            AppSpacing.s2,
            AppSpacing.s2,
            hasProgress ? AppSpacing.s2 : AppSpacing.s1,
          ),
          child: Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Color(0x80000000), blurRadius: 2)],
            ),
          ),
        ),
      ),
    );
  }
}

/// hover 上浮 3px（Q15/A5 可选项；原型 `.book:hover .book-cover`）。
class _HoverLift extends StatefulWidget {
  const _HoverLift({required this.child});

  final Widget child;

  @override
  State<_HoverLift> createState() => _HoverLiftState();
}

class _HoverLiftState extends State<_HoverLift> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hovering ? -3 : 0, 0),
        child: widget.child,
      ),
    );
  }
}

/// 列表磁贴（A5）：行高 78（AppLayout.listRowHeight），右侧 120px 线性
/// 进度 + 百分比（≤860 只留百分比）。
class BookListTile extends StatelessWidget {
  const BookListTile({
    super.key,
    required this.book,
    this.percent,
    this.syncStatus,
    this.localOnly = false,
    this.onOpen,
    this.onContextMenu,
  });

  final Book book;

  /// 阅读比例 0.0–1.0（null = 尚未阅读）。
  final double? percent;

  /// 每书同步状态（null = 「同步失败/待上传」条目自动让位）。
  final BookSyncStatus? syncStatus;

  /// 是否「仅本地」（docs/10 §4.7c）。
  final bool localOnly;

  /// 点行直接打开书（分流在页面）。
  final VoidCallback? onOpen;

  /// 右键 / 触屏长按的上下文菜单回调（全局坐标）。
  final void Function(Offset globalPosition)? onContextMenu;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final narrow = MediaQuery.sizeOf(context).width <= 860;
    final badgeKind = coverBadgeFor(
      book: book,
      localOnly: localOnly,
      syncStatus: syncStatus,
      percent: percent,
    );

    return TouchLongPressMenu(
      onMenu: (pos) => onContextMenu?.call(pos),
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            onContextMenu?.call(details.globalPosition),
        child: InkWell(
          onTap: onOpen,
          child: SizedBox(
            height: AppLayout.listRowHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
              child: Row(
                children: [
                  // 小封面（带阴影与圆角）。
                  SizedBox(
                    width: 44,
                    height: 62,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        boxShadow: t.sh1,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: CoverView(
                          coverPath: book.coverPath,
                          title: book.title,
                          author: book.author,
                          contentHash: book.contentHash,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s3),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.body.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                [
                                  if (book.author.trim().isNotEmpty)
                                    book.author,
                                  book.format.toUpperCase(),
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.caption.copyWith(color: t.text3),
                              ),
                            ),
                            if (badgeKind != null) ...[
                              const SizedBox(width: 6),
                              CoverBadge(kind: badgeKind, percent: percent),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s2),
                  // 右侧 120px 线性进度 + 百分比；移动端只留百分比。
                  if (!narrow && percent != null) ...[
                    SizedBox(
                      width: 120,
                      child: CoverProgressBar(percent: percent!),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                  ],
                  Text(
                    percent == null ? '' : formatPercent(percent!),
                    style: t.caption.copyWith(
                      color: t.text2,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
