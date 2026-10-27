/// 目录条目与解析结果实体（docs/03 §4.2、docs/05 §3.2 tocFingerprint）。
library;

/// 目录（TOC）条目。
///
/// [anchor] 是"跳转目标"，类型由各格式自定义（如 txt 的章节序号、
/// epub 的 spine 序号）。**锚点类必须实现稳定的 `toString()`**——
/// 它是目录指纹序列化的一部分（见 [TocFingerprint.compute]）。
class TocEntry {
  const TocEntry({
    required this.title,
    required this.level,
    required this.anchor,
  });

  /// 章节标题（展示用，可含序号）。
  final String title;

  /// 层级，0 起（`#` 一级标题 → 0）。
  final int level;

  /// 跳转目标，格式自定义类型（object）。各格式的锚点类型定义在其 handler 目录中。
  final Object anchor;
}
