/// 书架网格度量（纯 Dart 计算，可单测）。
///
/// 背景（v1.3.4 移动端书架密度）：v1.1 的网格把「列数」算了两次——页面用
/// `ceil(内容宽 / 176)` 推算卡片宽高比，`SliverGridDelegateWithMaxCrossAxisExtent`
/// 内部却按 `ceil(内容宽 / (176 + 16))` 真正排布。390 宽时前者得 3 列、
/// 后者实得 2 列，手机一屏只剩「2 列 × 1.5 行 ≈ 3 本」（用户反馈「2 * 1.5」）。
///
/// 本模块把「列数 / 卡宽 / 卡高 / 一屏几行」收敛成**唯一**来源：
/// 页面按它算 `childAspectRatio` 与卡片尺寸，测试按它断言
/// 「每行几本 / 一屏几行」，两侧不会再各算一套。
///
/// 两档规格：
/// - [LibraryGridSpec.comfortable]：宽屏（桌面/平板）——沿用 v1.1 观感：
///   封面 2:3 + 文字区（书名两行 + 作者 + 时长），列数自适应（1440 → 7 列）。
/// - [LibraryGridSpec.compact]：窄屏（手机）——3 列紧凑卡：封面 + 底部标题
///   叠加层（无文字区），封面比例按「一屏至少 3 行完整可见」自适应收缩。
library;

import '../../core/design_tokens.dart';

/// 网格规格档位。
enum LibraryGridSpec {
  /// 宽屏规格：封面 2:3 + 文字区（v1.1 原样）。
  comfortable,

  /// 窄屏规格：3 列紧凑卡，标题叠在封面底部。
  compact,
}

/// 宽屏档网格卡宽上限（v1.1 Q6：154px 起，7 列 @1440）。
const double libraryGridMaxCardExtent = 176;

/// 宽屏档封面宽高比（书籍标准 2:3）。
const double libraryGridComfortableCoverAspect = 2 / 3;

/// 宽屏档文字区高度（书名两行 36 + 作者 18 + 间距 6 + 时长 17 + 安全余量）。
const double libraryGridComfortableMetaHeight = 84;

/// 窄屏档断点：视口宽 ≤ 该值走紧凑卡（手机竖屏 320–520）。
const double libraryGridCompactMaxWidth = 520;

/// 窄屏档列数（固定 3 列）。
const int libraryGridCompactColumns = 3;

/// 窄屏档最小可见完整行数（验收口径：一屏至少 3 行 = 9 本）。
const int libraryGridCompactMinRows = 3;

/// 窄屏档封面高度系数（高/宽）的上限——书籍标准 2:3。
const double libraryGridCompactMaxCoverFactor = 1.5;

/// 窄屏档封面高度系数（高/宽）的下限——1:1（再扁就不像书了）。
const double libraryGridCompactMinCoverFactor = 1.0;

/// 按视口宽挑规格档位（窄屏 = 手机）。
LibraryGridSpec libraryGridSpecForWidth(double viewportWidth) =>
    viewportWidth <= libraryGridCompactMaxWidth
    ? LibraryGridSpec.compact
    : LibraryGridSpec.comfortable;

/// 网格度量结果（一次算清，页面与测试共用）。
class LibraryGridMetrics {
  const LibraryGridMetrics({
    required this.spec,
    required this.columns,
    required this.padding,
    required this.contentWidth,
    required this.contentHeight,
    required this.cardWidth,
    required this.coverAspectRatio,
    required this.coverHeight,
    required this.metaHeight,
    required this.cardHeight,
    required this.crossAxisSpacing,
    required this.mainAxisSpacing,
    required this.childAspectRatio,
    required this.rowsPerScreen,
  });

  /// 规格档位。
  final LibraryGridSpec spec;

  /// 列数。
  final int columns;

  /// 网格内边距（四边同值）。
  final double padding;

  /// 网格内容宽（已扣内边距）。
  final double contentWidth;

  /// 网格内容高（已扣内边距）。
  final double contentHeight;

  /// 卡片宽（= 实际排布宽，非估算值）。
  final double cardWidth;

  /// 封面宽高比（宽/高）。
  final double coverAspectRatio;

  /// 封面高。
  final double coverHeight;

  /// 卡片文字区高度（紧凑档为 0：标题叠在封面上）。
  final double metaHeight;

  /// 卡片总高（= 封面高 + 文字区高）。
  final double cardHeight;

  /// 列间距。
  final double crossAxisSpacing;

  /// 行间距。
  final double mainAxisSpacing;

  /// `SliverGridDelegate` 的宽高比（宽/高）。
  final double childAspectRatio;

  /// 视口内可见的**完整**行数。
  final int rowsPerScreen;

  /// 视口内可见的完整卡片数（= 行数 × 列数）。
  int get visibleBooks => rowsPerScreen * columns;

  /// 标题是否叠在封面上（紧凑档）。
  bool get overlayTitle => spec == LibraryGridSpec.compact;

  @override
  String toString() =>
      'LibraryGridMetrics(${spec.name}, 列 $columns, 卡 '
      '${cardWidth.toStringAsFixed(1)}×${cardHeight.toStringAsFixed(1)}, '
      '封面比 ${coverAspectRatio.toStringAsFixed(3)}, 一屏 $rowsPerScreen 行 / '
      '$visibleBooks 本)';
}

/// 计算网格度量。
///
/// [viewportWidth] / [viewportHeight] 是网格视口的尺寸（**含**网格内边距，
/// 即 `LayoutBuilder` 给到的 `constraints.maxWidth/maxHeight`）。
///
/// 宽屏档：列数沿用 v1.1 委托口径 `ceil(内容宽 / (176 + 16))`（与改造前
/// `SliverGridDelegateWithMaxCrossAxisExtent` 实得列数一致），卡宽取真实
/// 排布宽，封面 2:3 + 文字区 84px。
///
/// 窄屏档：固定 3 列，封面高度系数在 [libraryGridCompactMinCoverFactor]
/// ~ [libraryGridCompactMaxCoverFactor] 之间自适应——优先保留 2:3 的书籍
/// 感，但必须让 [libraryGridCompactMinRows] 行完整可见；矮屏上按需压扁
/// （最低 1:1）。
LibraryGridMetrics computeLibraryGridMetrics({
  required double viewportWidth,
  required double viewportHeight,
  required LibraryGridSpec spec,
}) {
  if (spec == LibraryGridSpec.compact) {
    return _compactMetrics(viewportWidth, viewportHeight);
  }
  return _comfortableMetrics(viewportWidth, viewportHeight);
}

LibraryGridMetrics _comfortableMetrics(
  double viewportWidth,
  double viewportHeight,
) {
  const double padding = AppSpacing.s4; // 16
  const double crossSpacing = AppSpacing.s4; // 16
  const double mainSpacing = AppSpacing.s5; // 20

  final contentWidth = (viewportWidth - padding * 2).clamp(
    1.0,
    double.infinity,
  );
  final contentHeight = (viewportHeight - padding * 2).clamp(
    0.0,
    double.infinity,
  );
  // 列数口径与改造前 `SliverGridDelegateWithMaxCrossAxisExtent(176)` 一致
  // （委托内部按 `ceil(内容宽 / (上限 + 列间距))` 排布）。
  final columns = (contentWidth / (libraryGridMaxCardExtent + crossSpacing))
      .ceil()
      .clamp(1, 99);
  final cardWidth = (contentWidth - crossSpacing * (columns - 1)) / columns;
  final coverHeight = cardWidth / libraryGridComfortableCoverAspect;
  final cardHeight = coverHeight + libraryGridComfortableMetaHeight;
  return LibraryGridMetrics(
    spec: LibraryGridSpec.comfortable,
    columns: columns,
    padding: padding,
    contentWidth: contentWidth,
    contentHeight: contentHeight,
    cardWidth: cardWidth,
    coverAspectRatio: libraryGridComfortableCoverAspect,
    coverHeight: coverHeight,
    metaHeight: libraryGridComfortableMetaHeight,
    cardHeight: cardHeight,
    crossAxisSpacing: crossSpacing,
    mainAxisSpacing: mainSpacing,
    childAspectRatio: cardWidth / cardHeight,
    rowsPerScreen: _rowsPerScreen(
      contentHeight: contentHeight,
      cardHeight: cardHeight,
      mainAxisSpacing: mainSpacing,
    ),
  );
}

LibraryGridMetrics _compactMetrics(
  double viewportWidth,
  double viewportHeight,
) {
  const double padding = AppSpacing.s3; // 12
  const double crossSpacing = AppSpacing.s3; // 12
  const double mainSpacing = AppSpacing.s3; // 12
  const int columns = libraryGridCompactColumns;

  final contentWidth = (viewportWidth - padding * 2).clamp(
    1.0,
    double.infinity,
  );
  final contentHeight = (viewportHeight - padding * 2).clamp(
    0.0,
    double.infinity,
  );
  final cardWidth = (contentWidth - crossSpacing * (columns - 1)) / columns;

  // 封面高度系数：先按「≥3 行完整可见」求上限，再夹到 [1:1, 2:3]。
  // 减 1px 是给 sliver 像素取整留余量，避免临界值把第 3 行挤成半张。
  final maxCoverHeight =
      (contentHeight + mainSpacing) / libraryGridCompactMinRows -
      mainSpacing -
      1;
  final fitFactor = cardWidth > 0
      ? maxCoverHeight / cardWidth
      : libraryGridCompactMaxCoverFactor;
  final coverFactor = fitFactor
      .clamp(libraryGridCompactMinCoverFactor, libraryGridCompactMaxCoverFactor)
      .toDouble();
  final coverHeight = cardWidth * coverFactor;
  return LibraryGridMetrics(
    spec: LibraryGridSpec.compact,
    columns: columns,
    padding: padding,
    contentWidth: contentWidth,
    contentHeight: contentHeight,
    cardWidth: cardWidth,
    coverAspectRatio: 1 / coverFactor,
    coverHeight: coverHeight,
    metaHeight: 0,
    cardHeight: coverHeight,
    crossAxisSpacing: crossSpacing,
    mainAxisSpacing: mainSpacing,
    childAspectRatio: cardWidth / coverHeight,
    rowsPerScreen: _rowsPerScreen(
      contentHeight: contentHeight,
      cardHeight: coverHeight,
      mainAxisSpacing: mainSpacing,
    ),
  );
}

/// 视口内可见的**完整**行数（含被截断的半张卡不计）。
int _rowsPerScreen({
  required double contentHeight,
  required double cardHeight,
  required double mainAxisSpacing,
}) {
  if (contentHeight <= 0 || cardHeight <= 0) return 0;
  final rows =
      (contentHeight + mainAxisSpacing) / (cardHeight + mainAxisSpacing);
  return rows.floor();
}
