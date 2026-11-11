/// txt 分页器（FR-202 + v1.2 B1 整行分页）：按**行边界**切页，纯函数、同输入同输出。
///
/// 不变量（单测锚定）：
/// - 确定性：同输入（文本/样式/视口）⇒ 完全相同的页区间列表；
/// - 连续性：`pages[i].endOffset == pages[i+1].startOffset`；
/// - 覆盖性：首页从 0 起、末页到 `text.length`，并集覆盖全章；
/// - 单调性：区间严格递增、每页至少 1 字符；
/// - 代理对安全：页界不落在 UTF-16 代理对中间（行起点以字素簇为单位，
///   天然不会劈开代理对，防御性断言另有单测）；
/// - **整行性（B1 新增）**：页界只落在行与行之间——任何一页的行要么整行
///   可见、要么完全不可见，页尾不足一行时留白，绝不切字。
///
/// 实现原理（B1，docs/10 A23）：对章内区间做**显示层整窗排版**
/// （[buildTxtDisplayText] 变换 + `TextPainter.layout`），用
/// `computeLineMetrics()` 量出每行行盒高度得到「每页可容纳行数 N」（量出的，
/// 不是按字号×行距推算的），再用 `getPositionForOffset` 取每行行首的显示层
/// 偏移，经插入点表映射回**原文字符坐标**后下刀——页界 = 某行的行首。
/// 测量与渲染共用同一显示变换（[txtDisplayText]），页内容排版与整窗排版
/// 的对应前缀完全一致，因此每页渲染行数 ≤ N 且首末行都是整行。
///
/// v1.1（docs/10 A10 中文排版）：显示层段落首行插 2em 全角空格缩进 +
/// `TextAlign.justify` 两端对齐，测量/渲染同参数；justify 只作用在断行后
/// 的空间分配上，不改变行断点（单测锚定）。
///
/// v1.2（B4 段距）：段落间可插**整行**空行（[TxtPaginationRequest.paragraphGapLines]），
/// 以行高为单位、不破坏行网格；空行属插入层，不改字符坐标语义。页首段落
/// 不插段距（跨页断开的段间距在页界自然收起），窗口测量与单页渲染用同一
/// 规则，两侧一致。
///
/// 章为页边界：分页只作用于单章文本，章末页不满也翻页（由渲染器逐章调用）。
/// 计算放 isolate：[TxtPaginator.paginate]（isolate 不可用时自动回退主 isolate）。
///
/// 已知边界：视口宽度不足 2em（缩进自身跨行）时整行性不再成立，切点退化为
/// 「至少推进 1 字符」的保底推进（此时任何分页方案都无法保证整行，该宽度
/// 低于可用下限，仅保证不丢内容、必然终止）。
library;

import 'package:flutter/foundation.dart';
// WidgetSpan / SizedBox 在 widgets 库（widgets 库再导出 painting）。
import 'package:flutter/widgets.dart';

import '../../reader_indent.dart';
import 'txt_chapter_splitter.dart';
/// 章题字号倍数（原型 `.rd-text .rd-chapter-title{font-size:1.32em}`）。
const double kChapterTitleScale = 1.32;


/// 显示层变换的插入点：在显示文本 [offset] 处插入了 [length] 个字符。
class TxtDisplayInsertion {
  const TxtDisplayInsertion(this.offset, this.length);

  /// 插入点在显示文本中的偏移（升序，互不重叠）。
  final int offset;

  /// 插入长度（段距空行 + 缩进）。
  final int length;
}

/// 显示层文本构建结果：变换后的 span 树 + 插入点表（显示坐标 → 原文坐标映射）。
class TxtDisplayBuild {
  const TxtDisplayBuild({
    required this.span,
    required this.insertions,
    this.indentCount = 0,
  });

  /// 变换后的显示层 span 树（段首缩进为行内占位符）。
  final TextSpan span;

  /// 插入点表（**扁平化文本坐标**，升序）。
  final List<TxtDisplayInsertion> insertions;

  /// 行内缩进占位符数量（= span 树里 WidgetSpan 的个数）。
  ///
  /// 测量侧要用它给 [TextPainter.setPlaceholderDimensions] 喂同样数量的
  /// 尺寸项（数量不等会触发引擎断言）。
  final int indentCount;

  /// 显示文本偏移 → 原文偏移。
  ///
  /// [displayOffset] 落在某个插入段内部时钳制到该插入点对应的原文偏移
  /// （插入字符不对应原文，例如行断点落在段距空行/缩进中间——此时以段首
  /// 作为页界，页与页在段落边界相接，仍然整行）。
  int originalOffsetOf(int displayOffset) {
    var consumed = 0;
    for (final insertion in insertions) {
      final end = insertion.offset + insertion.length;
      if (displayOffset <= insertion.offset) {
        return displayOffset - consumed;
      }
      if (displayOffset < end) {
        return insertion.offset - consumed;
      }
      consumed += insertion.length;
    }
    return displayOffset - consumed;
  }
}

/// 章内区间 [start, end) → 显示层 span 树构建（含插入点表）。
///
/// 分页器测量与渲染视图**必须共用**本函数（[txtDisplaySpan] 为其薄封装），
/// 保证两侧排版一致。规则：
/// - 区间起点在段落首（start == 0 或前一字符是 `\n`）且该段非空行 → 插入
///   缩进（不插段距：页首段落跨页收起段间距）；
/// - 区间内每个 `\n` 之后（下一段非空行）→ 插入「段距空行 × N + 缩进」；
///   段距只加在「前一行有内容」的段落首上（原文已有空行分隔的段落不再
///   叠加，避免双重空行）；
/// - 空行（`\n\n`）与 `\r` 起始行（CRLF 空行/孤立回车）不插入——空行插入
///   缩进会平白多出一行占位，破坏与裸文本排版的一致性；
/// - 只插入不删改：偏移坐标经 [TxtDisplayBuild.originalOffsetOf] 还原。
///
/// **坐标语义**：插入点表的长度用**扁平化文本坐标**——一个缩进占位符在
/// 扁平文本里只占 1 个字符（U+FFFC），段距空行占 N 个 `\n`；源文本每个
/// 字符占 1 个字符。
TxtDisplayBuild buildTxtDisplaySpans(
  String chapterText,
  int start,
  int end, {
  required TextStyle style,
  required double fontSize,
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) {
  final raw = chapterText.substring(start, end);
  final insertions = <TxtDisplayInsertion>[];
  if (start >= end) {
    return TxtDisplayBuild(
      span: TextSpan(style: style, text: raw),
      insertions: insertions,
    );
  }
  if (indentEm <= 0 && paragraphGapLines <= 0) {
    return TxtDisplayBuild(
      span: TextSpan(style: style, text: raw),
      insertions: insertions,
    );
  }
  final children = <InlineSpan>[];
  final buffer = StringBuffer();
  var flattened = 0; // 已产出的扁平化字符数（源字符 + 插入字符）
  var indentCount = 0;

  /// 把缓冲区里的连续文本作为一个 span 落盘。
  ///
  /// 必须成段提交：逐字符建 span 会把 UTF-16 代理对拆成两个非法字符串
  /// （引擎报「string is not well-formed UTF-16」）。
  void flush() {
    if (buffer.isEmpty) return;
    children.add(TextSpan(text: buffer.toString()));
    buffer.clear();
  }

  void addText(String text) {
    if (text.isEmpty) return;
    buffer.write(text);
    flattened += text.length;
  }

  /// 插入段距空行 + 段首缩进占位符，并记录插入点（扁平坐标）。
  void insertGapAndIndent(int gapLines) {
    final indentLength = indentEm > 0 ? 1 : 0; // 占位符在扁平文本里占 1 字符
    final length = gapLines + indentLength;
    if (length == 0) return;
    insertions.add(TxtDisplayInsertion(flattened, length));
    // 先把前面的正文落盘，再插空行与缩进占位符（span 顺序即显示顺序）。
    flush();
    if (gapLines > 0) {
      children.add(TextSpan(text: '\n' * gapLines));
      flattened += gapLines;
    }
    if (indentLength > 0) {
      children.add(readerIndentSpan(fontSize));
      flattened += 1;
      indentCount++;
    }
  }

  // 区间首段：段落首行且非空行才缩进（续页起点在段中则不缩进）；
  // 页首段落不插段距（跨页收起）。
  final atParagraphStart =
      start == 0 || chapterText.codeUnitAt(start - 1) == 0x0A;

  // 章题（章首行）：命中章节标题规则时用**标题样式**渲染（1.32em / 600），
  // 不缩进；行盒高度仍等于正文的一行高（Flutter 的 height 乘的是该 span
  // 的字号 → 取 行距倍数/1.32），行网格不被破坏。
  // （原型 `.rd-text .rd-chapter-title`；测量与渲染同一函数 → 页界一致。）
  final headingEnd = _chapterHeadingEnd(chapterText, start, end);
  if (headingEnd > start) {
    final headingStyle = _chapterHeadingStyle(style);
    children.add(
      TextSpan(
        text: chapterText.substring(start, headingEnd),
        style: headingStyle,
      ),
    );
    flattened += headingEnd - start;
  }

  if (atParagraphStart &&
      headingEnd <= start &&
      _paragraphHasContent(chapterText, start, end)) {
    insertGapAndIndent(0);
  }
  for (var i = headingEnd > start ? headingEnd : start; i < end; i++) {
    final unit = chapterText.codeUnitAt(i);
    addText(String.fromCharCode(unit));
    if (unit == 0x0A &&
        i + 1 < end &&
        _paragraphHasContent(chapterText, i + 1, end)) {
      final gap = _prevLineHasContent(chapterText, i, start)
          ? paragraphGapLines
          : 0;
      insertGapAndIndent(gap);
    }
  }
  flush();
  return TxtDisplayBuild(
    span: TextSpan(style: style, children: children),
    insertions: insertions,
    indentCount: indentCount,
  );
}

/// 章题行的结束偏移（不含换行符）；无章题时返回 [start]。
///
/// 判定：区间起点必须是**章的起点**（start == 0）且首行命中章节标题规则
/// （[TxtChapterSplitter.isHeadingLine]）——章题的样式由「章首行」决定，
/// 与切分器用同一套规则，避免两处判定漂移。
int _chapterHeadingEnd(String chapterText, int start, int end) {
  if (start != 0 || start >= end) return start;
  var lineEnd = chapterText.indexOf('\n', start);
  if (lineEnd < 0 || lineEnd > end) lineEnd = end;
  var line = chapterText.substring(start, lineEnd);
  if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
  if (line.isEmpty || !TxtChapterSplitter.isHeadingLine(line)) return start;
  return lineEnd;
}

/// 章题样式：字号 1.32em、字重 600、字距 0.02em；行盒高度仍等于正文一行高。
///
/// Flutter 的 `TextStyle.height` 乘的是**该 span 的字号**，故这里用
/// `行距倍数 / 1.32`，让章题行的行盒 = 正文字号 × 行距倍数（行网格不破）。
TextStyle _chapterHeadingStyle(TextStyle base) {
  final size = base.fontSize ?? 16;
  return base.copyWith(
    fontSize: size * kChapterTitleScale,
    fontWeight: FontWeight.w600,
    letterSpacing: size * 0.02,
    height: (base.height ?? 1.0) / kChapterTitleScale,
  );
}

/// 段落首字符是否为可显示内容（`\n` 与 `\r` 视为空行/回车，不缩进）。
bool _paragraphHasContent(String text, int start, int end) {
  if (start >= end) return false;
  final first = text.codeUnitAt(start);
  return first != 0x0A && first != 0x0D;
}

/// `\n` 所在行（[newlineIndex] 处的换行符结束的那一行）是否有内容。
///
/// 用于段距判定：上一行有内容才在段首插空行（原文已有空行分隔的段落
/// 不再叠加）。区间起点恒为行首（页界性质），故回扫不会跨出区间语义。
bool _prevLineHasContent(String text, int newlineIndex, int regionStart) {
  var i = newlineIndex - 1;
  if (i < regionStart) return false; // 上一行起始于区间外：不插段距
  while (i >= regionStart && text.codeUnitAt(i) != 0x0A) {
    i--;
  }
  // 行内容 = (i, newlineIndex)，剥掉 CRLF 的 '\r' 后判空。
  var end = newlineIndex;
  if (end > i + 1 && text.codeUnitAt(end - 1) == 0x0D) end--;
  return end > i + 1;
}

/// 章内区间 [start, end) → 显示层 span 树（不含插入点表的便捷封装）。
///
/// 渲染侧使用；分页测量请用 [buildTxtDisplaySpans]（需要坐标映射）。
TextSpan txtDisplaySpan(
  String chapterText,
  int start,
  int end, {
  required TextStyle style,
  required double fontSize,
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) => buildTxtDisplaySpans(
  chapterText,
  start,
  end,
  style: style,
  fontSize: fontSize,
  indentEm: indentEm,
  paragraphGapLines: paragraphGapLines,
).span;

/// 章内区间 [start, end) → **单页渲染**显示层 span 树。
///
/// 与 [txtDisplaySpan] 的差异：页界落在段首时区间以行终止符（`\n`/`\r\n`）
/// 结尾，该终止符属于「分页符」而非页面内容——引擎会给尾随终止符渲染一个
/// 空行盒（`'a\n'` 排出 2 行），把页尾撑出一行空白。剥掉它不改变任何可见
/// 内容与行断点（空行盒本无字形），页高恰为整行数。
TextSpan txtPageDisplaySpan(
  String chapterText,
  int start,
  int end, {
  required TextStyle style,
  required double fontSize,
  int indentEm = kReaderParagraphIndentEm,
  int paragraphGapLines = 0,
}) {
  // 剥掉属于分页符的行终止符（源区间末尾的 `\r\n` / `\n`）。
  var effectiveEnd = end;
  if (effectiveEnd > start &&
      chapterText.codeUnitAt(effectiveEnd - 1) == 0x0A) {
    effectiveEnd--;
    if (effectiveEnd > start &&
        chapterText.codeUnitAt(effectiveEnd - 1) == 0x0D) {
      effectiveEnd--;
    }
  }
  return txtDisplaySpan(
    chapterText,
    start,
    effectiveEnd,
    style: style,
    fontSize: fontSize,
    indentEm: indentEm,
    paragraphGapLines: paragraphGapLines,
  );
}

/// 页区间：章内字符偏移 [start, end)。
class TxtPageRange {
  const TxtPageRange({required this.start, required this.end});

  /// 页起始章内偏移（含）。
  final int start;

  /// 页结束章内偏移（不含）。
  final int end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TxtPageRange && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TxtPageRange($start..$end)';
}

/// 分页输入（isolate 可发送的纯数据）。
class TxtPaginationRequest {
  const TxtPaginationRequest({
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.viewportWidth,
    required this.viewportHeight,
    this.fontFamily,
    this.fontFamilyFallback,
    this.indentEm = kReaderParagraphIndentEm,
    this.paragraphGapLines = 0,
    this.textAlign = TextAlign.left,
  });

  /// 章内文本。
  final String text;

  /// 正文字号（逻辑像素）。
  final double fontSize;

  /// 行距倍数。
  final double lineHeight;

  /// 字体族（null = 平台默认）。
  final String? fontFamily;

  /// 字体回退栈（v1.1 衬线/黑体/楷体系统栈）。
  final List<String>? fontFamilyFallback;

  /// 段落首行缩进（A10；单位 em，0 = 不缩进，B4 开关）。
  ///
  /// 渲染为**行内不可见盒**（宽 = indentEm × 字号），不用空白字符——
  /// 两端对齐会吞掉行首空白（详见 [kReaderParagraphIndentEm] 的说明）。
  final int indentEm;

  /// 段距空行数（B4：0 = 紧 / 1 = 空一行 / 2 = 空两行；以整行为单位）。
  final int paragraphGapLines;

  /// 对齐方式（A10 两端对齐：渲染与测量同参数，justify 不改变行断点）。
  final TextAlign textAlign;

  /// 视口宽（已扣除页边距）。
  final double viewportWidth;

  /// 视口高（已扣除页边距）。
  final double viewportHeight;
}

/// isolate 入口：[compute] 的顶层函数。
List<TxtPageRange> paginateTxtChapter(TxtPaginationRequest request) =>
    TxtPaginator.paginateSync(request);

/// 分页器。
final class TxtPaginator {
  TxtPaginator._();

  /// 高度比较容差（浮点排版噪声）。
  static const double _heightEpsilon = 0.01;

  /// 首窗字符数：常规章节一次整窗排版即可完成分页；超大章按需扩窗
  /// （×4），单窗排版规模有上界，避免无章节超长 txt 一次性排全书。
  static const int _initialWindowChars = 1 << 15;

  /// 测试专用：跳过 isolate 直接同步分页（widget 测试的 FakeAsync 中
  /// isolate 消息无法到达，用此开关保持可测性）。
  @visibleForTesting
  static bool debugSyncPagination = false;

  /// 异步分页：优先 isolate（大章节不卡 UI），失败回退同步。
  static Future<List<TxtPageRange>> paginate(
    TxtPaginationRequest request,
  ) async {
    if (debugSyncPagination) return paginateSync(request);
    try {
      return await compute(paginateTxtChapter, request);
    } catch (_) {
      // 后台 isolate 不可用（如宿主限制）时回退主 isolate 计算。
      return paginateSync(request);
    }
  }

  /// 章内偏移 → 页序号：包含该偏移的页（最后一个 start ≤ offset 的页；
  /// offset 超出章长时落到末页）。空页表返回 0。
  static int pageIndexOf(List<TxtPageRange> pages, int offset) {
    if (pages.isEmpty) return 0;
    var lo = 0;
    var hi = pages.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (pages[mid].start <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 同步分页（纯函数；同一 TextPainter 排版结果下输出确定）。
  ///
  /// 算法（B1 整行分页）：滑动窗口整窗排版 → 行盒度量定「每页行数 N」
  /// → 每页取 N 个整行，页界 = 第 N+1 行的行首（显示坐标经插入点表映射
  /// 回原文字符坐标）。见库注释。
  static List<TxtPageRange> paginateSync(TxtPaginationRequest request) {
    final text = request.text;
    final length = text.length;
    if (length == 0) return const [TxtPageRange(start: 0, end: 0)];

    // 视口退化（未布局/极端设置）：整章一页，保证渲染器可用。
    if (request.viewportWidth <= 0 ||
        request.viewportHeight <= 0 ||
        request.fontSize <= 0 ||
        request.lineHeight <= 0) {
      return [TxtPageRange(start: 0, end: length)];
    }

    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      maxLines: null,
    );
    final pages = <TxtPageRange>[];
    try {
      var start = 0;
      var windowChars = _initialWindowChars;
      var linesPerPage = 0; // 首窗测量后固定（行高全章一致）
      while (start < length) {
        final windowEnd = (start + windowChars) < length
            ? start + windowChars
            : length;
        final build = buildTxtDisplaySpans(
          text,
          start,
          windowEnd,
          style: TextStyle(
            fontSize: request.fontSize,
            height: request.lineHeight,
            fontFamily: request.fontFamily,
            fontFamilyFallback: request.fontFamilyFallback,
          ),
          fontSize: request.fontSize,
          indentEm: request.indentEm,
          paragraphGapLines: request.paragraphGapLines,
        );
        painter.text = build.span;
        painter.textAlign = request.textAlign;
        // 行内缩进占位符的尺寸：裸 TextPainter 不会自动量 WidgetSpan，
        // 必须手动喂（数量须与 span 树里的占位符个数一致）。
        painter.setPlaceholderDimensions(
          List<PlaceholderDimensions>.filled(
            build.indentCount,
            readerIndentPlaceholder(request.fontSize),
          ),
        );
        painter.layout(maxWidth: request.viewportWidth);
        final metrics = painter.computeLineMetrics();

        if (linesPerPage <= 0) {
          linesPerPage = _maxLinesFitting(metrics, request.viewportHeight);
        }

        // 每行行首的显示坐标（行盒几何 → 位置，不依赖 getLineBoundary 的
        // 换行符归属语义）。
        final lineStarts = _lineStartOffsets(painter, metrics);
        // 需要第 N 行（0 起）的行首作为切点；窗口行数不足且未到章尾 → 扩窗。
        if (lineStarts.length <= linesPerPage && windowEnd < length) {
          windowChars *= 4;
          continue;
        }

        final int pageEnd;
        if (lineStarts.length <= linesPerPage) {
          // 剩余不足一页（窗口已到章尾）：整段落尾作末页。
          pageEnd = windowEnd;
        } else {
          // 行首显示坐标 → 窗内相对偏移（display 0 ↔ 窗口起点）→ 章内绝对偏移。
          final cut = start + build.originalOffsetOf(lineStarts[linesPerPage]);
          // 防御推进（极端窄视口下切点可能映射回页首）：至少推进 1 字符，
          // 保证必然终止（与旧内核的「1 字符页」语义一致）。
          pageEnd = cut > start ? cut : (start + 1).clamp(0, length);
        }
        pages.add(TxtPageRange(start: start, end: pageEnd));
        start = pageEnd;
      }
    } finally {
      painter.dispose();
    }
    return pages;
  }

  /// 视口高度能容纳的整行数：前 k 行行盒高度和 ≤ 视口高 + 容差的最大 k，
  /// 至少 1（视口不足一行时每页 1 行，保证推进）。
  static int _maxLinesFitting(List<LineMetrics> metrics, double viewportHeight) {
    var used = 0.0;
    var count = 0;
    for (final metric in metrics) {
      final next = used + metric.height;
      if (next > viewportHeight + _heightEpsilon) break;
      used = next;
      count++;
    }
    return count < 1 ? 1 : count;
  }

  /// 每行行首的显示坐标：对每行取行盒垂直中点、水平左缘处的最近字符位置
  /// （LTR 下即该行首字符）。空行的行首即其换行符位置，同样有效。
  static List<int> _lineStartOffsets(TextPainter painter, List<LineMetrics> metrics) {
    final starts = List<int>.filled(metrics.length, 0);
    for (var i = 0; i < metrics.length; i++) {
      final metric = metrics[i];
      final top = metric.baseline - metric.ascent;
      final position = painter.getPositionForOffset(
        Offset(0, top + metric.height / 2),
      );
      starts[i] = position.offset;
    }
    return starts;
  }
}
