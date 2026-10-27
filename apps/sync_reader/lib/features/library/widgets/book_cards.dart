/// 书库条目卡片（FR-105）：网格卡片与列表磁贴，网格/列表两种视图复用。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../data/db/app_database.dart';
import '../../../shared/cover_view.dart';
import '../../../shared/format_utils.dart';

/// 封面宽高比（书籍标准 2:3）。
const double kCoverAspectRatio = 2 / 3;

/// "仅云端"角标（占位书，localPath 为空；M2 云端目录预留样式）。
class CloudOnlyBadge extends StatelessWidget {
  const CloudOnlyBadge({super.key, this.alignment = Alignment.topRight});

  /// 在封面上的位置。
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: alignment,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: const BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(6),
            bottomRight: Radius.circular(6),
          ),
        ),
        child: const Text(
          '仅云端',
          style: TextStyle(color: Colors.white, fontSize: 9),
        ),
      ),
    );
  }
}

/// 网格卡片：封面 + 书名 + 进度百分比 + 阅读时长徽标。
class BookGridCard extends StatelessWidget {
  const BookGridCard({
    super.key,
    required this.book,
    this.percent,
    this.onOpen,
  });

  final Book book;

  /// 阅读比例 0.0–1.0（null = 尚未阅读）。
  final double? percent;

  /// 打开详情回调（默认 go `/book/:bookId`）。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onOpen ?? () => context.push('/book/${book.bookId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                CoverView(
                  coverPath: book.coverPath,
                  title: book.title,
                  author: book.author,
                  contentHash: book.contentHash,
                ),
                if (book.localPath == null) const CloudOnlyBadge(),
                if (percent != null)
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      color: Colors.black45,
                      child: Text(
                        formatPercent(percent!),
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            book.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              if (book.totalSeconds > 0) ...[
                Icon(
                  Icons.schedule,
                  size: 10,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 2),
                Flexible(
                  child: Text(
                    humanizeDuration(book.totalSeconds),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// 列表磁贴：小封面 + 书名/作者/进度行 + "仅云端"角标。
class BookListTile extends StatelessWidget {
  const BookListTile({
    super.key,
    required this.book,
    this.percent,
    this.onOpen,
  });

  final Book book;

  /// 阅读比例 0.0–1.0（null = 尚未阅读）。
  final double? percent;

  /// 打开详情回调（默认 go `/book/:bookId`）。
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final stats = <String>[
      if (percent != null) formatPercent(percent!),
      if (book.totalSeconds > 0) humanizeDuration(book.totalSeconds),
      humanizeBytes(book.sizeBytes),
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: SizedBox(
        width: 44,
        height: 64,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CoverView(
              coverPath: book.coverPath,
              title: book.title,
              author: book.author,
              contentHash: book.contentHash,
            ),
            if (book.localPath == null) const CloudOnlyBadge(),
          ],
        ),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          if (book.author.trim().isNotEmpty) book.author,
          book.format.toUpperCase(),
          ...stats,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: book.localPath == null
          ? const Text('仅云端', style: TextStyle(fontSize: 11))
          : null,
      onTap: onOpen ?? () => context.push('/book/${book.bookId}'),
      dense: true,
    );
  }
}
