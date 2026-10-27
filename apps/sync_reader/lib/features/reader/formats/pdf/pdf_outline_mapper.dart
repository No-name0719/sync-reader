/// pdf outline → TocEntry 的纯映射逻辑（FR-205）。
///
/// 拆两层便于单测（flutter test 环境无 pdfium.dll，无法真实打开 pdf）：
/// 1. [flattenPdfOutline]：pdfrx 的 `PdfOutlineNode` 树 → 扁平的
///    [OutlineItem] 中间结构（喂伪造节点即可测试）；
/// 2. [outlineItemsToTocEntries]：[OutlineItem] 列表 → 契约 [TocEntry]。
library;

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../contract/toc_entry.dart';
import 'pdf_page_anchor.dart';

/// 扁平化的目录条目中间结构（与 pdfrx 类型解耦，可直接构造测试）。
class OutlineItem {
  const OutlineItem({
    required this.title,
    required this.pageIndex,
    required this.depth,
  });

  /// 条目标题（原文，不裁剪）。
  final String title;

  /// 目标页码（0 起；入参来自 outline dest 的 1 起页码减 1）。
  final int pageIndex;

  /// 原始嵌套深度（根为 0；子节点恒比父节点深 1，跳级时会出现空洞）。
  final int depth;
}

/// 深度优先展平 outline 树。
///
/// - 无有效页码的条目（dest 为 null，或 dest.pageNumber < 1，pdfium 对
///   命名目标解析失败时给 0）**跳过本条目但仍递归其子节点**；
/// - 子节点深度 = 父深度 + 1（被跳过的父节点不折叠深度，由
///   [outlineItemsToTocEntries] 统一规整）。
List<OutlineItem> flattenPdfOutline(
  List<pdfrx.PdfOutlineNode> nodes, {
  int depth = 0,
}) {
  final result = <OutlineItem>[];
  for (final node in nodes) {
    final pageNumber = node.dest?.pageNumber ?? 0;
    if (pageNumber >= 1) {
      result.add(
        OutlineItem(title: node.title, pageIndex: pageNumber - 1, depth: depth),
      );
    }
    result.addAll(flattenPdfOutline(node.children, depth: depth + 1));
  }
  return result;
}

/// [OutlineItem] 列表 → 契约目录条目。
///
/// 层级规整：按深度首次出现的顺序映射为 0 起的连续层级（无空洞），
/// 防止根节点无页码被跳过后目录从 level=1 开始。
List<TocEntry> outlineItemsToTocEntries(List<OutlineItem> items) {
  if (items.isEmpty) return const [];
  final levelMap = <int, int>{};
  return [
    for (final item in items)
      TocEntry(
        title: item.title,
        level: levelMap.putIfAbsent(item.depth, () => levelMap.length),
        anchor: PdfPageAnchor(pageIndex: item.pageIndex),
      ),
  ];
}

/// 无 outline 书籍的页数指纹条目（FR-205：无 toc 时对页数指纹）。
///
/// 仅参与 [TocFingerprint] 序列化（title/anchor 的 toString 稳定），
/// **不进入 UI 目录、不可跳转**——anchor 为普通字符串，渲染器
/// `jumpTo` 对非 [PdfPageAnchor] 锚点直接忽略。
TocEntry pagesFingerprintEntry(int pageCount) =>
    TocEntry(title: 'pages:$pageCount', level: 0, anchor: 'pages:$pageCount');
