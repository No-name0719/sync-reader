/// txt 锚点：章节序号 + 章内字符偏移（docs/05 §3.3 type=txt）。
///
/// `charOffset` 为章内 **UTF-16 码元** 偏移（Dart String 下标语义）；
/// anchor 的 [toString] 是目录指纹序列化的一部分，格式必须稳定：
/// `txt:chapter:<i>:<off>`。
library;

/// txt 章节锚点（TocEntry.anchor 与 progress locator 共用）。
class TxtChapterAnchor {
  const TxtChapterAnchor({required this.chapterIndex, this.charOffset = 0});

  /// 从 locator JSON 的解码 Map 构造（不做越界校验，由调用方钳制）。
  factory TxtChapterAnchor.fromValues(int chapterIndex, int charOffset) =>
      TxtChapterAnchor(chapterIndex: chapterIndex, charOffset: charOffset);

  /// 章节序号（0 起，与 toc 下标对应）。
  final int chapterIndex;

  /// 章内字符偏移。
  final int charOffset;

  @override
  String toString() => 'txt:chapter:$chapterIndex:$charOffset';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TxtChapterAnchor &&
          chapterIndex == other.chapterIndex &&
          charOffset == other.charOffset;

  @override
  int get hashCode => Object.hash(chapterIndex, charOffset);
}
