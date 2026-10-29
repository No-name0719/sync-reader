/// 书籍封面组件（FR-103 / v1.1 A17）：有封面文件 → Image.file；无 →
/// 「纸底墨字」生成封面（极低饱和纸底 + 同色系深墨首字 + 内框线 +
/// 标题/作者排版 + 品牌色小横线，Q8）。
///
/// 纸底/墨色由 contentHash 推导同一色相（饱和度 12%、亮度 90% 纸底，
/// 原型 app.js `coverArt` 逐字对应），同一本书颜色稳定、跨端重启不变；
/// 深色模式用深纸底 + 浅墨（原型未覆盖深色书库屏，此处按同一色相
/// 亮度反转补齐，保持可读）。
/// 真封面（PDF 首页缩略图 / EPUB 内嵌封面）仍走图片路径，不受影响。
/// 网格卡片与详情页复用本组件，尺寸/圆角由调用方约束。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../core/design_tokens.dart' show AppFonts;

/// 由 contentHash（`sha256:<hex>`）稳定推导色相（0–359）。
///
/// 取哈希前 8 个 hex 字符累加映射；哈希为空/非法时回落蓝灰色相 210。
/// 纯函数，可测试。
double hashHue(String contentHash) {
  final hex = contentHash.startsWith('sha256:')
      ? contentHash.substring(7)
      : contentHash;
  var value = 0;
  for (var i = 0; i < hex.length && i < 8; i++) {
    final digit = int.tryParse(hex[i], radix: 16);
    if (digit == null) break;
    value = value * 16 + digit;
  }
  return (value % 360).toDouble();
}

/// 「纸底墨字」生成封面的配色（同一色相的纸底/墨色/内框线）。
@immutable
class PaperCoverPalette {
  const PaperCoverPalette({
    required this.background,
    required this.ink,
    required this.rule,
  });

  /// 纸底色（低饱和）。
  final Color background;

  /// 墨色（同色系深色/深色模式下的浅色）。
  final Color ink;

  /// 内框线色。
  final Color rule;

  @override
  bool operator ==(Object other) =>
      other is PaperCoverPalette &&
      other.background == background &&
      other.ink == ink &&
      other.rule == rule;

  @override
  int get hashCode => Object.hash(background, ink, rule);
}

/// 由 contentHash 推导纸底墨字配色（A17/Q8；原型 app.js `coverArt`）：
///
/// - 浅色：纸底 `hsl(h 12% 90%)`、墨色 `hsl(h 22% 26%)`、框线 `hsl(h 14% 80%)`；
/// - 深色：同色相反转——深纸底 `hsl(h 12% 16%)`、浅墨 `hsl(h 20% 86%)`、
///   框线 `hsl(h 14% 28%)`（原型未覆盖，按同一规则补齐）。
/// 纯函数，可测试。
PaperCoverPalette paperPaletteFromHash(
  String contentHash, {
  required bool dark,
}) {
  final hue = hashHue(contentHash);
  if (dark) {
    return PaperCoverPalette(
      background: HSLColor.fromAHSL(1, hue, 0.12, 0.16).toColor(),
      ink: HSLColor.fromAHSL(1, hue, 0.20, 0.86).toColor(),
      rule: HSLColor.fromAHSL(1, hue, 0.14, 0.28).toColor(),
    );
  }
  return PaperCoverPalette(
    background: HSLColor.fromAHSL(1, hue, 0.12, 0.90).toColor(),
    ink: HSLColor.fromAHSL(1, hue, 0.22, 0.26).toColor(),
    rule: HSLColor.fromAHSL(1, hue, 0.14, 0.80).toColor(),
  );
}

/// 书名首字（纸底封面的大字）：取第一个字素（正确处理 CJK/emoji）。
String leadingGlyphs(String text, {int count = 1}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '书';
  return trimmed.characters.take(count).toString();
}

/// 书籍封面视图。
///
/// [coverPath] 非空时尝试加载本地封面图（加载失败自动回落纸底墨字封面）；
/// [title]/[author]/[contentHash] 用于生成封面。组件填满父级约束
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

  /// 书名（封面主/小字）。
  final String title;

  /// 作者（封面小字，可空串）。
  final String author;

  /// 内容哈希（纸底取色种子）。
  final String contentHash;

  /// 圆角。
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final path = coverPath;
    final Widget content;
    if (path == null || path.isEmpty) {
      content = _PaperCover(
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
        errorBuilder: (_, _, _) =>
            _PaperCover(title: title, author: author, contentHash: contentHash),
      );
    }
    return ClipRRect(borderRadius: borderRadius, child: content);
  }
}

/// 纸底墨字生成封面（A17/Q8；对照原型 `.book-cover.paper`）：
/// 内框线 + 居中大字（衬线）+ 底部「品牌色小横线 + 书名 + 作者」。
/// 字号随封面宽度等比缩放（原型容器查询 clamp 的 Flutter 转写），
/// 保证 112px（手机 3 列）到 175px（桌面 7 列）都不重叠。
class _PaperCover extends StatelessWidget {
  const _PaperCover({
    required this.title,
    required this.author,
    required this.contentHash,
  });

  final String title;
  final String author;
  final String contentHash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = paperPaletteFromHash(
      contentHash,
      dark: theme.brightness == Brightness.dark,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // 原型：glyph clamp(26px, 30cqi, 46px)；title clamp(9.5, 6.8cqi, 12)；
        // author clamp(8.5, 6cqi, 10.5)；横线宽 22cqi 上限 26px。
        final glyphSize = (width * 0.30).clamp(26.0, 46.0);
        final titleSize = (width * 0.068).clamp(9.5, 12.0);
        final authorSize = (width * 0.06).clamp(8.5, 10.5);
        final ruleWidth = (width * 0.22).clamp(0.0, 26.0);
        return Container(
          color: palette.background,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 内框线（inset 7px，1px 框线，圆角 3）。
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(7),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: palette.rule),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  Expanded(
                    child: Center(
                      child: Text(
                        leadingGlyphs(title),
                        style: TextStyle(
                          fontFamily: AppFonts.serif,
                          fontSize: glyphSize,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                    ),
                  ),
                  // 底部排版：品牌色小横线 + 书名（最多 3 行）+ 作者。
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      width * 0.09,
                      width * 0.06,
                      width * 0.09,
                      width * 0.11,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: ruleWidth,
                          height: 2,
                          decoration: BoxDecoration(
                            // 品牌色（AppTheme 把 colorScheme.primary 映射到
                            // t.brand；共享组件不硬性依赖令牌扩展）。
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        SizedBox(height: width * 0.06),
                        Text(
                          title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: titleSize,
                            height: 1.4,
                            fontWeight: FontWeight.w600,
                            color: palette.ink,
                          ),
                        ),
                        if (author.trim().isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: authorSize,
                              height: 1.2,
                              color: palette.ink.withValues(alpha: 0.68),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
