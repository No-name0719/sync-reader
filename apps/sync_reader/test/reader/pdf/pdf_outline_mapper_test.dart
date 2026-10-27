/// outline → TocEntry 展平映射单测（FR-205）：
/// 多级嵌套 / 空 outline / 无页码条目跳过 / 深度规整 / 页数指纹条目。
///
/// pdfrx 的 `PdfOutlineNode`/`PdfDest` 为纯数据类，可直接构造伪造树，
/// 无需 pdfium。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/contract/toc_fingerprint.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_outline_mapper.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_page_anchor.dart';

/// 便捷构造 outline 节点。
pdfrx.PdfOutlineNode node(
  String title,
  int? pageNumber, [
  List<pdfrx.PdfOutlineNode> children = const [],
]) => pdfrx.PdfOutlineNode(
  title: title,
  dest: pageNumber == null
      ? null
      : pdfrx.PdfDest(pageNumber, pdfrx.PdfDestCommand.xyz, null),
  children: children,
);

void main() {
  group('flattenPdfOutline', () {
    test('空 outline → 空列表', () {
      expect(flattenPdfOutline(const []), isEmpty);
    });

    test('多级嵌套按深度优先展平，深度正确', () {
      final items = flattenPdfOutline([
        node('第1章', 1, [
          node('1.1', 2, [node('1.1.1', 3)]),
          node('1.2', 4),
        ]),
        node('第2章', 5),
      ]);
      expect(items.map((e) => (e.title, e.pageIndex, e.depth)).toList(), [
        ('第1章', 0, 0),
        ('1.1', 1, 1),
        ('1.1.1', 2, 2),
        ('1.2', 3, 1),
        ('第2章', 4, 0),
      ]);
    });

    test('无 dest / pageNumber<1 的条目跳过，但子节点仍参与展平', () {
      final items = flattenPdfOutline([
        node('无dest', null, [node('子A', 10)]),
        node('页码0', 0, [node('子B', 11)]),
        node('负页码', -3),
      ]);
      expect(items.map((e) => (e.title, e.pageIndex, e.depth)).toList(), [
        ('子A', 9, 1), // 父被跳过 → 子保持自身深度（规整交给下一层）
        ('子B', 10, 1),
      ]);
    });

    test('dest 页码 1-based → 0-based（第 42 页 → 41）', () {
      final items = flattenPdfOutline([node('目标', 42)]);
      expect(items.single.pageIndex, 41);
    });
  });

  group('outlineItemsToTocEntries', () {
    test('空输入 → 空目录', () {
      expect(outlineItemsToTocEntries(const []), isEmpty);
    });

    test('深度规整为 0 起连续层级（无跳级空洞）', () {
      final entries = outlineItemsToTocEntries([
        const OutlineItem(title: '子A', pageIndex: 9, depth: 1),
        const OutlineItem(title: '孙', pageIndex: 12, depth: 2),
        const OutlineItem(title: '子B', pageIndex: 10, depth: 1),
        const OutlineItem(title: '根', pageIndex: 0, depth: 0),
      ]);
      expect(entries.map((e) => (e.title, e.level)).toList(), [
        ('子A', 0),
        ('孙', 1),
        ('子B', 0),
        ('根', 2),
      ]);
    });

    test('正常层级原样保留（0 起连续）', () {
      final entries = outlineItemsToTocEntries([
        const OutlineItem(title: 'A', pageIndex: 0, depth: 0),
        const OutlineItem(title: 'A1', pageIndex: 1, depth: 1),
        const OutlineItem(title: 'B', pageIndex: 5, depth: 0),
      ]);
      expect(entries.map((e) => e.level), [0, 1, 0]);
    });

    test('锚点为 PdfPageAnchor 且 toString 稳定（指纹契约）', () {
      final entries = outlineItemsToTocEntries([
        const OutlineItem(title: 'A', pageIndex: 41, depth: 0),
      ]);
      final anchor = entries.single.anchor;
      expect(anchor, isA<PdfPageAnchor>());
      expect(anchor.toString(), 'pdf:page:41:0.0');
      // 同输入两次计算指纹一致
      final again = outlineItemsToTocEntries([
        const OutlineItem(title: 'A', pageIndex: 41, depth: 0),
      ]);
      expect(TocFingerprint.compute(entries), TocFingerprint.compute(again));
    });
  });

  group('pagesFingerprintEntry（无 outline 的页数指纹）', () {
    test('title/anchor 稳定且区分页数', () {
      final e1 = pagesFingerprintEntry(120);
      final e2 = pagesFingerprintEntry(120);
      final e3 = pagesFingerprintEntry(121);
      expect(e1.title, 'pages:120');
      expect(e1.anchor.toString(), 'pages:120');
      expect(TocFingerprint.compute([e1]), TocFingerprint.compute([e2]));
      expect(TocFingerprint.compute([e1]), isNot(TocFingerprint.compute([e3])));
    });

    test('页数指纹 ≠ 空 toc 指纹（能区分"有 outline 但为空"）', () {
      final pages = TocFingerprint.compute([pagesFingerprintEntry(0)]);
      final empty = TocFingerprint.compute(const <TocEntry>[]);
      expect(pages, isNot(empty));
    });
  });
}
