/// txt 进度坐标换算（docs/05 §3.3）：locator JSON 编解码 + percent 双向映射。
///
/// locator 形如 `{"type":"txt","chapterIndex":87,"charOffset":1204}`；
/// percent =（当前章之前所有章字符总数 + 章内偏移）/ 全书总字符数，∈[0,1]。
/// 偏移均为 UTF-16 码元语义（Dart String 下标）。
library;

import 'dart:convert';

import 'txt_chapter.dart';
import 'txt_chapter_anchor.dart';

/// locator 编解码与校验（纯函数）。
final class TxtLocator {
  TxtLocator._();

  /// locator 判别联合的 type 取值。
  static const String type = 'txt';

  /// 编码为 locator JSON。
  static String encode(int chapterIndex, int charOffset) => jsonEncode({
    'type': type,
    'chapterIndex': chapterIndex,
    'charOffset': charOffset,
  });

  /// 从 [ProgressAnchor.decodeLocator] 的结果解码并校验。
  ///
  /// 非法（type 不符 / 字段缺失或非整数 / 负值）返回 null，调用方走
  /// percent 降级；章越界不在此校验（需章表，由渲染器钳制后降级）。
  static TxtChapterAnchor? decode(Map<String, Object?>? json) {
    if (json == null || json['type'] != type) return null;
    final chapterIndex = _asNonNegativeInt(json['chapterIndex']);
    final charOffset = _asNonNegativeInt(json['charOffset']);
    if (chapterIndex == null || charOffset == null) return null;
    return TxtChapterAnchor(chapterIndex: chapterIndex, charOffset: charOffset);
  }

  static int? _asNonNegativeInt(Object? value) =>
      value is int && value >= 0 ? value : null;
}

/// percent ↔（章，章内偏移）换算（纯函数）。
final class TxtPercentMath {
  TxtPercentMath._();

  /// 当前位置的全书比例。
  ///
  /// [chapters] 须为 [TxtChapterSplitter] 产物（区间相接、覆盖全文）；
  /// 退化（空章表/全书 0 字符）返回 0。
  static double percentOf(
    List<TxtChapter> chapters,
    int chapterIndex,
    int charOffset,
  ) {
    if (chapters.isEmpty) return 0;
    final total = chapters.last.endOffset;
    if (total <= 0) return 0;
    final i = chapterIndex.clamp(0, chapters.length - 1);
    final chapter = chapters[i];
    final offset = charOffset.clamp(0, chapter.length);
    final read = chapter.startOffset + offset;
    return (read / total).clamp(0.0, 1.0);
  }

  /// percent → 章序号：映射到该比例**所在章的章首**（docs/05 §3.3 降级规则
  /// "percent 定位到最近章节开头"）。
  static int chapterIndexAtPercent(List<TxtChapter> chapters, double percent) {
    if (chapters.isEmpty) return 0;
    final total = chapters.last.endOffset;
    if (total <= 0) return 0;
    final target = (percent.clamp(0.0, 1.0) * total).round();
    // 二分找最后一个 startOffset <= target 的章。
    var lo = 0;
    var hi = chapters.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (chapters[mid].startOffset <= target) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
