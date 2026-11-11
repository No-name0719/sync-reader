/// txt 章节切分器（FR-202）：逐行扫描启发式规则表，命中行作为章起点。
///
/// 纯 Dart 实现（无 Flutter 依赖），输出字符偏移区间，便于单测与 isolate 复用。
///
/// 规则（按序匹配，命中即止；规则表为常量 [TxtChapterSplitter.rules]）：
/// 1. 章回式："第X章/卷/回/节/部/篇/集"，X 支持中文数字（一二三…百千万两〇）
///    与阿拉伯数字，允许"第 一 章"等空白变体；
/// 2. 特殊章题：序章/楔子/引子/前言/尾声/后记/番外（可带短标题或序号后缀）；
/// 3. 行首独立数字编号："一、标题" / "12. 标题"（带防误切护栏：
///    分隔符后不能紧跟数字（排除 3.14/127.0.0.1），整行不得含代码标点）。
///
/// 无任何命中 → 单章全文；首章之前有正文 → 生成"开篇"章。
library;

import 'txt_chapter.dart';

/// 章节切分器。
final class TxtChapterSplitter {
  TxtChapterSplitter._();

  /// 章题最大长度（命中行去空白后截断）。
  static const int maxTitleLength = 50;

  /// 首个命中章之前的散落正文生成的章题。
  static const String preambleChapterTitle = '开篇';

  /// 整书无章节命中时的唯一章题。
  static const String singleChapterTitle = '正文';

  /// —— 规则表（常量，单测直接断言每条规则的行为）——

  /// 规则 1：章回式标题。
  /// `[^\n]{0,48}` 限定章题尾巴长度：长段落行不会因行首恰为"第X章"误切。
  static final RegExp chapterHeading = RegExp(
    r'^[\s　]*第[\s　]*(?:[0-9０-９]+|[〇零一二三四五六七八九十百千万两]+)'
    r'[\s　]*[章回节卷部篇集][^\n]{0,48}$',
  );

  /// 规则 2：特殊章题（可带分隔符短标题或数字/中文数字序号后缀）。
  /// 无分隔符且后随普通正文（如"前言不搭后语…"整句）不命中。
  static final RegExp specialHeading = RegExp(
    r'^[\s　]*(?:序章|楔子|引子|前言|尾声|后记|番外)'
    r'(?:[\s　:：·・.．,，、\-—－(（][^\n]{0,40}|[0-9０-９一二三四五六七八九十百]{1,8})?'
    r'[\s　]*$',
  );

  /// 规则 3：行首独立数字编号 + 分隔标点 + 标题。
  /// 仅认显式分隔标点（顿号/点/逗/冒），裸数字行不切（防误切代码/数据行）。
  static final RegExp numericHeading = RegExp(
    r'^[\s　]*(?:[0-9０-９]{1,4}|[一二三四五六七八九十百]{1,8})'
    r'[\s　]*[、.．,，:：][\s　]*[^\n]{1,40}$',
  );

  /// 代码式伪行护栏：含这些字符的行不适用规则 3（如 `1. x = 1;`）。
  static const String numericRuleForbiddenChars = r';；=<>{}[]`~';

  /// 规则标识（单测用；[split] 内部按此序匹配）。
  static const List<String> ruleIds = [
    'chapterHeading',
    'specialHeading',
    'numericHeading',
  ];

  /// 返回命中单行文本的规则 id；不命中返回 null（单测用）。
  /// 该行是否命中章节标题规则（任一规则）。
  ///
  /// 显示层用它判定「章首行是不是章题」——章题要用标题样式渲染
  /// （1.32em / 600，见 [buildTxtDisplaySpans]），正文行不适用。
  static bool isHeadingLine(String line) => ruleIdForLine(line) != null;

  static String? ruleIdForLine(String line) {
    // 规则 3 有额外护栏：分隔符后紧跟数字 → 小数/IP/年份类，不切；
    // 含代码标点 → 代码式伪行，不切。
    if (numericHeading.hasMatch(line)) {
      final m = numericHeading.firstMatch(line)!;
      final sep = m.group(0)!;
      final sepIdx = _separatorIndexIn(sep);
      if (sepIdx >= 0 && sepIdx + 1 < sep.length) {
        final after = sep[sepIdx + 1];
        final isDigit =
            (after.codeUnitAt(0) >= 0x30 && after.codeUnitAt(0) <= 0x39) ||
            (after.codeUnitAt(0) >= 0xFF10 && after.codeUnitAt(0) <= 0xFF19);
        if (isDigit) return null;
      }
      final forbidden = numericRuleForbiddenChars.runes.toSet();
      final hasForbidden = line.runes.any(forbidden.contains);
      if (!hasForbidden) return 'numericHeading';
    }
    if (chapterHeading.hasMatch(line)) return 'chapterHeading';
    if (specialHeading.hasMatch(line)) return 'specialHeading';
    return null;
  }

  /// 在规则 3 匹配到的前缀里找分隔标点的位置（护栏定位用）。
  static int _separatorIndexIn(String matchedPrefix) {
    const separators = '、.．,，:：';
    for (var i = 0; i < matchedPrefix.length; i++) {
      if (separators.contains(matchedPrefix[i])) return i;
    }
    return -1;
  }

  /// 切分全文为章节列表。
  ///
  /// 保证：章节按 [TxtChapter.startOffset] 升序；相邻章区间相接
  /// （`chapters[i].endOffset == chapters[i+1].startOffset`）；
  /// 首章从 0 开始（首命中前有内容则生成"开篇"章）、末章到 `text.length`。
  static List<TxtChapter> split(String text) {
    final starts = <_ChapterStart>[];
    var lineStart = 0;
    while (lineStart <= text.length) {
      var newline = text.indexOf('\n', lineStart);
      if (newline < 0) newline = text.length;
      var line = text.substring(lineStart, newline);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final ruleId = ruleIdForLine(line);
      if (ruleId != null) {
        starts.add(
          _ChapterStart(
            offset: lineStart,
            title: _cleanTitle(line),
            ruleId: ruleId,
          ),
        );
      }
      if (newline >= text.length) break;
      lineStart = newline + 1;
    }

    if (starts.isEmpty) {
      return [
        TxtChapter(
          title: singleChapterTitle,
          startOffset: 0,
          endOffset: text.length,
        ),
      ];
    }

    final chapters = <TxtChapter>[];
    if (starts.first.offset > 0) {
      chapters.add(
        TxtChapter(
          title: preambleChapterTitle,
          startOffset: 0,
          endOffset: starts.first.offset,
        ),
      );
    }
    for (var i = 0; i < starts.length; i++) {
      final end = i + 1 < starts.length ? starts[i + 1].offset : text.length;
      chapters.add(
        TxtChapter(
          title: starts[i].title,
          startOffset: starts[i].offset,
          endOffset: end,
        ),
      );
    }
    return chapters;
  }

  /// 章题 = 命中行去首尾空白，限长 [maxTitleLength]。
  static String _cleanTitle(String line) {
    final trimmed = line.trim();
    if (trimmed.length <= maxTitleLength) return trimmed;
    return trimmed.substring(0, maxTitleLength);
  }
}

/// 章起点内部记录。
class _ChapterStart {
  const _ChapterStart({
    required this.offset,
    required this.title,
    required this.ruleId,
  });

  final int offset;
  final String title;
  final String ruleId;
}
