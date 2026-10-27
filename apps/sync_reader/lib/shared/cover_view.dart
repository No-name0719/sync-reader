/// 书籍封面组件（FR-103）：有封面文件 → Image.file；无 → 统一风格文字封面。
///
/// 文字封面底色由 contentHash 推导（同一本书颜色稳定，跨端重启不变）；
/// 网格卡片与详情页复用本组件，尺寸/圆角由调用方约束。
library;

import 'dart:io';

import 'package:flutter/material.dart';

/// 由 contentHash（`sha256:<hex>`）稳定推导柔和封面底色。
///
/// 取哈希前 8 个 hex 字符映射到色相（0–359），饱和度/亮度固定为柔和值；
/// 哈希为空/非法时回落蓝灰色相 210。纯函数，可测试。
Color coverColorFromHash(String contentHash) {
  final hex = contentHash.startsWith('sha256:')
      ? contentHash.substring(7)
      : contentHash;
  var value = 0;
  for (var i = 0; i < hex.length && i < 8; i++) {
    final digit = int.tryParse(hex[i], radix: 16);
    if (digit == null) break;
    value = value * 16 + digit;
  }
  final hue = (value % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.42, 0.72).toColor();
}

/// 由 contentHash 推导文字封面前景色（比底色深一档，保证对比度）。
Color coverForegroundFromHash(String contentHash) {
  final hex = contentHash.startsWith('sha256:')
      ? contentHash.substring(7)
      : contentHash;
  var value = 0;
  for (var i = 0; i < hex.length && i < 8; i++) {
    final digit = int.tryParse(hex[i], radix: 16);
    if (digit == null) break;
    value = value * 16 + digit;
  }
  final hue = (value % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.45, 0.24).toColor();
}

/// 书名前缀字（文字封面的大字）：取前 [count] 个字素（正确处理 CJK/emoji）。
String leadingGlyphs(String text, {int count = 2}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '书';
  return trimmed.characters.take(count).toString();
}

/// 书籍封面视图。
///
/// [coverPath] 非空时尝试加载本地封面图（加载失败自动回落文字封面）；
/// [title]/[author]/[contentHash] 用于生成文字封面。组件填满父级约束
/// （网格卡片外层用 AspectRatio 控制比例）。
class CoverView extends StatelessWidget {
  const CoverView({
    super.key,
    this.coverPath,
    required this.title,
    this.author = '',
    required this.contentHash,
    this.borderRadius = const BorderRadius.all(Radius.circular(6)),
  });

  /// 本地封面文件路径（可空 = 无封面）。
  final String? coverPath;

  /// 书名（文字封面主/小字）。
  final String title;

  /// 作者（文字封面小字，可空串）。
  final String author;

  /// 内容哈希（文字封面取色种子）。
  final String contentHash;

  /// 圆角。
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final path = coverPath;
    final Widget content;
    if (path == null || path.isEmpty) {
      content = _FallbackCover(
        title: title,
        author: author,
        contentHash: contentHash,
      );
    } else {
      content = Image.file(
        File(path),
        fit: BoxFit.cover,
        // 测试环境的 fakeAsync 中文件 IO 不完成：placeholder 必须是静态帧。
        frameBuilder: (context, child, frame, wasSync) => child,
        errorBuilder: (_, _, _) => _FallbackCover(
          title: title,
          author: author,
          contentHash: contentHash,
        ),
      );
    }
    return ClipRRect(borderRadius: borderRadius, child: content);
  }
}

/// 统一风格文字封面：大字（书名前 1–2 字）+ 书名/作者小字，底色哈希取色。
class _FallbackCover extends StatelessWidget {
  const _FallbackCover({
    required this.title,
    required this.author,
    required this.contentHash,
  });

  final String title;
  final String author;
  final String contentHash;

  @override
  Widget build(BuildContext context) {
    final background = coverColorFromHash(contentHash);
    final foreground = coverForegroundFromHash(contentHash);
    return Container(
      color: background,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            flex: 3,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  leadingGlyphs(title),
                  style: TextStyle(
                    color: foreground,
                    fontSize: 40,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ),
          if (author.trim().isNotEmpty)
            Flexible(
              child: Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: foreground, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}
