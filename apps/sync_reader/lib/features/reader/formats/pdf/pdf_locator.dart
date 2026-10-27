/// pdf locator 编解码 + restore 决策 + 页码输入校验（FR-205/FR-207、
/// docs/05 §3.3）。全部为纯函数/纯值对象，可独立单测（测试环境无 pdfium）。
///
/// locator 契约（docs/05 §3.3）：
/// `{"type":"pdf","pageIndex":n,"yRatio":x,"readingDir":"ltr"}`；
/// percent = 已读页数占比 = (pageIndex+1)/pageCount。
library;

import 'dart:convert';

import '../../contract/progress_anchor.dart';

/// 解析后的 pdf locator。
class PdfLocator {
  const PdfLocator({
    required this.pageIndex,
    this.yRatio = 0,
    this.readingDir = 'ltr',
  });

  /// 0 起页码。
  final int pageIndex;

  /// 页内纵向比例 0.0–1.0。
  final double yRatio;

  /// 阅读方向提示（M1 恒为 ltr）。
  final String readingDir;
}

/// 序列化为 locator JSON（schema 演进只增不删，键序无关）。
String encodePdfLocator(int pageIndex, double yRatio) => jsonEncode({
  'type': 'pdf',
  'pageIndex': pageIndex,
  'yRatio': yRatio,
  'readingDir': 'ltr',
});

/// 从 locator JSON 解析；非 pdf 类型/结构损坏/缺页码字段 → null（调用方降级）。
///
/// 对跨端数值形态保持容忍：`pageIndex` 接受整型 num（如 `41.0`）。
PdfLocator? parsePdfLocator(String? locatorJson) {
  if (locatorJson == null || locatorJson.isEmpty) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(locatorJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  if (decoded['type'] != 'pdf') return null;
  final pageIndex = switch (decoded['pageIndex']) {
    final int i => i,
    final num n when n % 1 == 0 => n.toInt(),
    _ => null,
  };
  if (pageIndex == null) return null;
  final yRatio = switch (decoded['yRatio']) {
    final num n => n.toDouble(),
    _ => 0.0,
  };
  final readingDir = switch (decoded['readingDir']) {
    final String s when s.isNotEmpty => s,
    _ => 'ltr',
  };
  return PdfLocator(
    pageIndex: pageIndex,
    yRatio: yRatio.clamp(0.0, 1.0),
    readingDir: readingDir,
  );
}

/// 页码 → 全书阅读比例（percent = 已读页数占比）。
///
/// [pageIndex] 越界时按 clamp 处理；[pageCount] <= 0 视为 0。
double percentForPage(int pageIndex, int pageCount) {
  if (pageCount <= 0) return 0;
  return ((pageIndex + 1) / pageCount).clamp(0.0, 1.0);
}

/// percent → 最近页码（[percentForPage] 的逆换算，docs/05 §3.3 双向换算）。
///
/// percent = (i+1)/n 的反函数取整：`round(percent*n - 1)`，
/// 保证 i → percent → i 精确往返（含首尾页）。
int pageIndexForPercent(double percent, int pageCount) {
  if (pageCount <= 0) return 0;
  if (percent <= 0) return 0;
  final index = (percent.clamp(0.0, 1.0) * pageCount - 1).round();
  return index.clamp(0, pageCount - 1);
}

/// restore 决策结果。
class PdfRestoreDecision {
  const PdfRestoreDecision({
    required this.mode,
    required this.targetPageIndex,
    this.yRatio = 0,
    required this.applied,
  });

  /// 恢复模式（如实告知宿主）。
  final ReaderRestoreMode mode;

  /// 应跳转的目标页（0 起）；noProgress 时为 0（即保持开头）。
  final int targetPageIndex;

  /// 页内纵向比例（仅 exact 恢复可能非 0）。
  final double yRatio;

  /// 实际生效的锚点（契约：降级时 percent 保持不变、locator 为空对象）。
  final ProgressAnchor applied;
}

/// restore 决策表（docs/05 §3.3 恢复规则的编码级实现）：
///
/// | 输入                                   | mode                | 目标页             |
/// |----------------------------------------|---------------------|--------------------|
/// | 无进度（hasProgress=false）            | noProgress          | 0（保持开头）      |
/// | locator 为 pdf 且页码在界内            | exact               | locator 页码       |
/// | locator 损坏/类型不符/页码越界         | degradedToPercent   | percent 换算最近页 |
/// | [pageCount] <= 0（退化文档）           | noProgress          | 0                  |
PdfRestoreDecision decideRestore(ProgressAnchor saved, int pageCount) {
  if (!saved.hasProgress || pageCount <= 0) {
    return PdfRestoreDecision(
      mode: ReaderRestoreMode.noProgress,
      targetPageIndex: 0,
      applied: ProgressAnchor.empty,
    );
  }
  final locator = parsePdfLocator(saved.locatorJson);
  final inRange =
      locator != null &&
      locator.pageIndex >= 0 &&
      locator.pageIndex < pageCount;
  if (inRange) {
    final index = locator.pageIndex;
    final yRatio = locator.yRatio;
    return PdfRestoreDecision(
      mode: ReaderRestoreMode.exact,
      targetPageIndex: index,
      yRatio: yRatio,
      applied: ProgressAnchor(
        locatorJson: encodePdfLocator(index, yRatio),
        percent: percentForPage(index, pageCount),
      ),
    );
  }
  return PdfRestoreDecision(
    mode: ReaderRestoreMode.degradedToPercent,
    targetPageIndex: pageIndexForPercent(saved.percent, pageCount),
    applied: ProgressAnchor(locatorJson: '{}', percent: saved.percent),
  );
}

/// 页码跳转输入校验（1 起的用户输入 → 0 起页码）。
///
/// 非整数/越界（<1 或 >[pageCount]）/空串 → null；[pageCount] <= 0 → null。
int? parsePageInput(String raw, int pageCount) {
  if (pageCount <= 0) return null;
  final value = int.tryParse(raw.trim());
  if (value == null || value < 1 || value > pageCount) return null;
  return value - 1;
}
