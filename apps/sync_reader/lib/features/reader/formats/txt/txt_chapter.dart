/// 章节切分产物：一个章节 = 标题 + 全文中的字符区间 [startOffset, endOffset)。
///
/// 偏移为 **UTF-16 码元** 偏移（Dart String 下标语义），区间两两相接、
/// 并集覆盖整书文本——这是 percent/locator 换算的几何基础。
library;

/// 切分出的章节（isolate 可发送的纯数据类）。
class TxtChapter {
  const TxtChapter({
    required this.title,
    required this.startOffset,
    required this.endOffset,
  });

  /// 章题（命中行去首尾空白并截断至 [TxtChapterSplitter.maxTitleLength]；
  /// 无命中整书单章时为固定占位题）。
  final String title;

  /// 章起始字符偏移（含；命中行的行首）。
  final int startOffset;

  /// 章结束字符偏移（不含；下一章起始或全文末尾）。
  final int endOffset;

  /// 章内字符数。
  int get length => endOffset - startOffset;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TxtChapter &&
          title == other.title &&
          startOffset == other.startOffset &&
          endOffset == other.endOffset;

  @override
  int get hashCode => Object.hash(title, startOffset, endOffset);

  @override
  String toString() => 'TxtChapter($title, $startOffset..$endOffset)';
}
