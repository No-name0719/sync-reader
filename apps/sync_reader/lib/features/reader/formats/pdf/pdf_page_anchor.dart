/// pdf 锚点：页码(0-based) + 页内纵向比例（docs/05 §3.3 type=pdf）。
///
/// **锚点类必须实现稳定 `toString()`**（TocEntry 契约）：指纹序列化与
/// 跨端目录比对都依赖它，格式一经发布不可更改。
library;

/// pdf 目录/进度锚点。
class PdfPageAnchor {
  const PdfPageAnchor({required this.pageIndex, this.yRatio = 0});

  /// 0 起页码。
  final int pageIndex;

  /// 页内纵向比例 0.0–1.0（视口顶部在页内的位置；0 = 页顶）。
  final double yRatio;

  /// 稳定序列化：`pdf:page:<pageIndex>:<yRatio>`（指纹契约，勿改格式）。
  @override
  String toString() => 'pdf:page:$pageIndex:$yRatio';
}
