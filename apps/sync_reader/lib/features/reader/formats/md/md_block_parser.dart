/// md 块级结构解析器（FR-204）：把 md 源文本解析为块列表，供 TOC 提取、
/// 分块渲染与进度定位（blockIndex/charOffset）共用。
///
/// 职责边界：本解析器**只负责块边界与块类型**（逐行状态机）；
/// 块内 GFM 行内语法（加粗/链接/表格对齐等）交给 flutter_markdown_plus 渲染，
/// 因此 [MdBlock.content] 保留原始 md 源文本（含围栏标记、表格线等）。
///
/// 消歧规则（CommonMark/GFM 语义的工程简化版）：
/// - 围栏代码块（``` / ~~~）内的行一律是代码内容——`#` 不是标题、`---` 不是
///   分隔线/二级标题、`| - |` 不是表格（修复基线"逐行正则误切代码块"缺陷）；
/// - Setext 标题（下划线 `===`/`---`）仅在**紧贴未闭合段落**时成立；
///   `---` 前无段落时是主题分隔线（hr），`***`/`___`/`- - -` 永远是 hr；
/// - 表格（GFM）：本行含 `|` 且下一行是定界行（单元格均为 `:?-+:?`）→ 表格，
///   优先级高于 Setext；
/// - 列表：`-`/`*`/`+` 无序与 `1.`/`1)` 有序；嵌套/续行（缩进行）与松散列表
///   （空行分隔）归并为**一个**块；
/// - 引用块：连续 `>` 行归并为一个块（CommonMark 的"懒惰续行"简化为不归并）。
///
/// 纯 Dart 实现，无 Flutter 依赖，`flutter test` 直接可测。
library;

import '../../contract/toc_entry.dart';
import 'md_locator.dart';

/// 块类型。
enum MdBlockType {
  /// ATX/Setext 标题。
  heading,

  /// 普通段落。
  paragraph,

  /// 列表（无序/有序/嵌套/松散，整段归并为一个块）。
  list,

  /// 围栏代码块（``` 或 ~~~；含围栏行本身）。
  codeBlock,

  /// 引用块（连续 `>` 行）。
  quote,

  /// GFM 表格（表头行 + 定界行 + 后续表格行）。
  table,

  /// 独占一行的图片（`![alt](src)`）。
  image,

  /// 主题分隔线（--- / *** / ___ / - - - 等）。
  hr,
}

/// md 源文本中的一个顶层块。
class MdBlock {
  const MdBlock({
    required this.type,
    required this.sourceStart,
    required this.sourceEnd,
    required this.content,
    this.level = 0,
    this.title = '',
  });

  /// 块类型。
  final MdBlockType type;

  /// 标题级：heading 为 1..6（Setext `=`→1、`-`→2）；其余块为 0。
  final int level;

  /// 块在源文本中的起始字符偏移（UTF-16 code unit，含行首缩进）。
  final int sourceStart;

  /// 块结束偏移（开区间，不含末行换行符）。
  final int sourceEnd;

  /// 块的原始 md 源文本（= 源文本 substring(sourceStart, sourceEnd)），
  /// 直接交给 MarkdownBody 渲染。
  final String content;

  /// 标题文本（TOC 用，已去 `#`/行尾 `#`/首尾空白）；非 heading 块为空串。
  final String title;

  @override
  String toString() =>
      'MdBlock(${type.name}, level=$level, [$sourceStart,$sourceEnd), '
      'title="$title")';
}

/// 源文本行（含偏移信息，供 sourceStart/sourceEnd 计算）。
class MdSourceLine {
  const MdSourceLine(this.text, this.start);

  /// 行文本（不含换行符）。
  final String text;

  /// 行首在源文本中的偏移。
  final int start;

  /// 行尾偏移（开区间，不含换行符）。
  int get end => start + text.length;
}

/// 块解析器（无状态，可 const 复用）。
class MdBlockParser {
  const MdBlockParser();

  // ---- 行级语法判定（CommonMark 简化版，缩进上限 3 空格） ----

  /// ATX 标题：`#{1,6}` + 空格（或行尾）+ 内容；行尾 ` #+` 收尾可剥离。
  static final _atxHeading = RegExp(
    r'^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$',
  );

  /// 围栏开行：``` 或 ~~~（可带 info string）。
  static final _fenceOpen = RegExp(r'^ {0,3}(`{3,}|~{3,})');

  /// Setext 一级下划线（仅 `=`）。
  static final _setextEquals = RegExp(r'^ {0,3}=+[ \t]*$');

  /// Setext 二级下划线（仅 `-`；与 hr 的消歧见 [parse] 内注释）。
  static final _setextDash = RegExp(r'^ {0,3}-+[ \t]*$');

  /// 主题分隔线：`---`、`***`、`___`、`- - -`、`* * *`、`_ _ _` 等。
  static final _thematicBreak = RegExp(r'^ {0,3}(?:[-*_][ \t]*){3,}$');

  /// 引用行。
  static final _quoteLine = RegExp(r'^ {0,3}>');

  /// 无序列表项（缩进 0-3 起判；更深的缩进由"列表续行"规则归并）。
  static final _unorderedItem = RegExp(r'^ {0,3}[-*+][ \t]');

  /// 有序列表项（`1.` 或 `1)`；标记后须为空白或行尾）。
  static final _orderedItem = RegExp(r'^ {0,3}\d{1,9}[.)](?:[ \t].*)?$');

  /// 独占一行的图片。
  static final _imageOnly = RegExp(r'^ *!\[[^\]]*\]\([^)]*\) *$');

  /// 表格定界行单元格：`:---`、`---:`、`:---:`、`---`（可带首尾空格）。
  static final _tableDelimiterCell = RegExp(r'^ *:?-+:? *$');

  /// 解析全文为块列表。[source] 为解码后的 md 全文；空文本返回空列表。
  List<MdBlock> parse(String source) {
    final blocks = <MdBlock>[];
    final lines = splitLines(source);
    if (lines.isEmpty) return blocks;

    var i = 0;
    final paragraph = <MdSourceLine>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      final first = paragraph.first;
      final last = paragraph.last;
      final content = source.substring(first.start, last.end);
      final isImage = paragraph.length == 1 && _imageOnly.hasMatch(first.text);
      blocks.add(
        MdBlock(
          type: isImage ? MdBlockType.image : MdBlockType.paragraph,
          sourceStart: first.start,
          sourceEnd: last.end,
          content: content,
          title: isImage ? _imageAltOf(first.text) : '',
        ),
      );
      paragraph.clear();
    }

    while (i < lines.length) {
      final line = lines[i];
      final text = line.text;

      // 空行：终止段落，不属于任何块。
      if (text.trim().isEmpty) {
        flushParagraph();
        i++;
        continue;
      }

      // 围栏开行：吞到闭合行（或文末）。围栏内的 # / --- / | 均为代码内容。
      final fence = _fenceOpen.firstMatch(text);
      if (fence != null) {
        flushParagraph();
        i = _consumeFence(blocks, source, lines, i, fence);
        continue;
      }

      // ATX 标题。
      final atx = _atxHeading.firstMatch(text);
      if (atx != null) {
        flushParagraph();
        blocks.add(
          MdBlock(
            type: MdBlockType.heading,
            level: atx.group(1)!.length,
            sourceStart: line.start,
            sourceEnd: line.end,
            content: source.substring(line.start, line.end),
            title: (atx.group(2) ?? '').trim(),
          ),
        );
        i++;
        continue;
      }

      // Setext 下划线：仅当紧贴未闭合段落时成立（`===`→一级、`---`→二级）；
      // 否则落到下面的主题分隔线/段落分支。
      if (paragraph.isNotEmpty &&
          (_setextEquals.hasMatch(text) || _setextDash.hasMatch(text))) {
        i = _consumeSetext(
          blocks,
          source,
          paragraph,
          line,
          i,
          level: _setextEquals.hasMatch(text) ? 1 : 2,
        );
        continue;
      }

      // 主题分隔线（`***`/`___`/`- - -`/无段落紧贴时的 `---`）。
      if (_thematicBreak.hasMatch(text)) {
        flushParagraph();
        blocks.add(
          MdBlock(
            type: MdBlockType.hr,
            sourceStart: line.start,
            sourceEnd: line.end,
            content: source.substring(line.start, line.end),
          ),
        );
        i++;
        continue;
      }

      // GFM 表格：本行含 `|` 且下一行是定界行（优先级高于 Setext）。
      if (text.contains('|') &&
          i + 1 < lines.length &&
          _isTableDelimiterRow(lines[i + 1].text)) {
        flushParagraph();
        i = _consumeTable(blocks, source, lines, i);
        continue;
      }

      // 引用块。
      if (_quoteLine.hasMatch(text)) {
        flushParagraph();
        i = _consumeQuote(blocks, source, lines, i);
        continue;
      }

      // 列表（含嵌套缩进与松散空行，归并为一个块）。
      if (_isListItem(text)) {
        flushParagraph();
        i = _consumeList(blocks, source, lines, i);
        continue;
      }

      // 其余：段落内容（累积到遇结构性块/空行为止）。
      paragraph.add(line);
      i++;
    }
    flushParagraph();
    return blocks;
  }

  /// 按行切分源文本并记录行偏移（兼容 \r\n / \n / \r）。
  static List<MdSourceLine> splitLines(String source) {
    final lines = <MdSourceLine>[];
    var lineStart = 0;
    var buffer = StringBuffer();
    for (var i = 0; i < source.length; i++) {
      final ch = source[i];
      if (ch == '\r' || ch == '\n') {
        lines.add(MdSourceLine(buffer.toString(), lineStart));
        buffer.clear();
        // \r\n 算一个换行符。
        if (ch == '\r' && i + 1 < source.length && source[i + 1] == '\n') i++;
        lineStart = i + 1;
      } else {
        buffer.write(ch);
      }
    }
    // 末行无换行符也成一行；文末有换行符则不追加空行。
    if (lineStart < source.length || buffer.isNotEmpty) {
      lines.add(MdSourceLine(buffer.toString(), lineStart));
    }
    return lines;
  }

  /// 是否列表项（无序/有序；缩进 0-3 起判，深层缩进项由续行规则归并）。
  static bool _isListItem(String text) =>
      _unorderedItem.hasMatch(text) || _orderedItem.hasMatch(text);

  /// 深层缩进（≥1 空格/制表符）的非空行：列表续行/嵌套项。
  static bool _isIndented(String text) =>
      text.startsWith(' ') || text.startsWith('\t');

  /// 独占一行图片的 alt 文本。
  static String _imageAltOf(String line) =>
      RegExp(r'!\[([^\]]*)\]').firstMatch(line)?.group(1) ?? '';

  /// 表格定界行判定：剥首尾 `|` 后按 `|` 切分，每个单元格都是 `:?-+:?`。
  /// 行内须同时含 `|` 与 `-`（`---` 单独成行不是定界行，避免与 Setext/hr 冲突）。
  static bool _isTableDelimiterRow(String line) {
    var t = line.trim();
    if (!t.contains('|') || !t.contains('-')) return false;
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    if (t.isEmpty) return false;
    return t.split('|').every(_tableDelimiterCell.hasMatch);
  }

  /// 消费围栏代码块：开行 + 内容行 + 闭合行，返回下一行下标。
  int _consumeFence(
    List<MdBlock> blocks,
    String source,
    List<MdSourceLine> lines,
    int openIndex,
    RegExpMatch openMatch,
  ) {
    final fenceChar = openMatch.group(1)![0];
    final fenceLen = openMatch.group(1)!.length;
    final closing = RegExp('^ {0,3}$fenceChar{$fenceLen,}[ \t]*\$');
    var end = openIndex;
    while (end < lines.length) {
      if (end > openIndex && closing.hasMatch(lines[end].text)) break;
      end++;
    }
    // end == 闭合行下标；文未闭合则 end == lines.length（吞到底）。
    final lastLine = end < lines.length ? lines[end] : lines[lines.length - 1];
    final start = lines[openIndex].start;
    final stop = lastLine.end;
    blocks.add(
      MdBlock(
        type: MdBlockType.codeBlock,
        sourceStart: start,
        sourceEnd: stop,
        content: source.substring(start, stop),
      ),
    );
    return end < lines.length ? end + 1 : end;
  }

  /// 消费 Setext 标题：累积段落 + 下划线行合并为一个 heading 块，
  /// 返回下一行下标。
  int _consumeSetext(
    List<MdBlock> blocks,
    String source,
    List<MdSourceLine> paragraph,
    MdSourceLine underline,
    int underlineIndex, {
    required int level,
  }) {
    final title = [
      for (final l in paragraph)
        if (l.text.trim().isNotEmpty) l.text.trim(),
    ].join(' ');
    final start = paragraph.first.start;
    paragraph.clear();
    blocks.add(
      MdBlock(
        type: MdBlockType.heading,
        level: level,
        sourceStart: start,
        sourceEnd: underline.end,
        content: source.substring(start, underline.end),
        title: title,
      ),
    );
    return underlineIndex + 1;
  }

  /// 消费表格：表头 + 定界行 + 后续含 `|` 行，返回下一行下标。
  int _consumeTable(
    List<MdBlock> blocks,
    String source,
    List<MdSourceLine> lines,
    int headerIndex,
  ) {
    var end = headerIndex + 2; // 表头 + 定界行之后
    while (end < lines.length &&
        lines[end].text.trim().isNotEmpty &&
        lines[end].text.contains('|')) {
      end++;
    }
    final start = lines[headerIndex].start;
    final stop = lines[end - 1].end;
    blocks.add(
      MdBlock(
        type: MdBlockType.table,
        sourceStart: start,
        sourceEnd: stop,
        content: source.substring(start, stop),
      ),
    );
    return end;
  }

  /// 消费引用块：连续 `>` 行，返回下一行下标。
  int _consumeQuote(
    List<MdBlock> blocks,
    String source,
    List<MdSourceLine> lines,
    int firstIndex,
  ) {
    var end = firstIndex;
    while (end < lines.length && _quoteLine.hasMatch(lines[end].text)) {
      end++;
    }
    final start = lines[firstIndex].start;
    final stop = lines[end - 1].end;
    blocks.add(
      MdBlock(
        type: MdBlockType.quote,
        sourceStart: start,
        sourceEnd: stop,
        content: source.substring(start, stop),
      ),
    );
    return end;
  }

  /// 消费列表块：列表项 + 缩进续行/嵌套项 + 松散空行，归并为一个块，
  /// 返回下一行下标。
  int _consumeList(
    List<MdBlock> blocks,
    String source,
    List<MdSourceLine> lines,
    int firstIndex,
  ) {
    var end = firstIndex;
    while (end < lines.length) {
      final text = lines[end].text;
      if (text.trim().isEmpty) {
        // 松散列表：空行仅当其后仍是列表项/缩进续行时才并入。
        var k = end + 1;
        while (k < lines.length && lines[k].text.trim().isEmpty) {
          k++;
        }
        if (k < lines.length &&
            (_isListItem(lines[k].text) || _isIndented(lines[k].text))) {
          end = k;
          continue;
        }
        break;
      }
      if (_isListItem(text) || _isIndented(text)) {
        end++;
        continue;
      }
      break;
    }
    final start = lines[firstIndex].start;
    final stop = lines[end - 1].end;
    blocks.add(
      MdBlock(
        type: MdBlockType.list,
        sourceStart: start,
        sourceEnd: stop,
        content: source.substring(start, stop),
      ),
    );
    return end;
  }
}

/// 从块列表提取目录：标题块 → TocEntry（level 0 起 = `#` 级 -1；
/// anchor = [MdHeadingAnchor]{headingIndex=第几个标题, charOffset=块 sourceStart}）。
///
/// 无标题文档返回空列表（调用方按"单章"处理）。
List<TocEntry> buildTocFromBlocks(List<MdBlock> blocks) {
  var headingOrdinal = 0;
  return [
    for (final block in blocks)
      if (block.type == MdBlockType.heading)
        TocEntry(
          title: block.title,
          level: (block.level - 1).clamp(0, 5),
          anchor: MdHeadingAnchor(
            headingIndex: headingOrdinal++,
            charOffset: block.sourceStart,
          ),
        ),
  ];
}
