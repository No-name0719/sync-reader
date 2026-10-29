/// txt 分页器（FR-202）：TextPainter 二分贪心切页，纯函数、同输入同输出。
///
/// 不变量（单测锚定）：
/// - 确定性：同输入（文本/样式/视口）⇒ 完全相同的页区间列表；
/// - 连续性：`pages[i].endOffset == pages[i+1].startOffset`；
/// - 覆盖性：首页从 0 起、末页到 `text.length`，并集覆盖全章；
/// - 单调性：区间严格递增、每页至少 1 字符；
/// - 代理对安全：页界不落在 UTF-16 代理对中间。
///
/// v1.1（docs/10 A10 中文排版）：测量与渲染共用 [txtDisplayText] —— 段落
/// 首行插入 2em 全角空格缩进，保证分页测量与视图渲染的排版完全一致；
/// 缩进字符只出现在显示层，**不改页区间的字符坐标语义**（locator 兼容）。
///
/// 两端对齐说明（A10 结论）：Flutter 3.47 的 `TextPainter` 支持
/// `TextAlign.justify`（libtxt 引擎级两端对齐，仅作用于软换行行，显式
/// `\n` 结尾的段落末行保持左对齐，正是中文排版要的行为）。分页器按
/// 整块测量（非逐行排版），justify 与视图渲染同参数，行断点与高度一致。
///
/// 章为页边界：分页只作用于单章文本，章末页不满也翻页（由渲染器逐章调用）。
/// 计算放 isolate：[TxtPaginator.paginate]（isolate 不可用时自动回退主 isolate）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../contract/reader_settings.dart' show kReaderParagraphIndent;

/// 段落首行缩进量（A10：2em 全角空格，单一事实源见
/// reader_settings.dart 的 [kReaderParagraphIndent]）。
const String txtParagraphIndent = kReaderParagraphIndent;

/// 章内区间 [start, end) → 显示文本：对区间内每个段落首行插入 [indent]。
///
/// 分页器测量与渲染视图**必须共用**本函数，保证两侧排版一致。规则：
/// - 区间起点在段落首（start == 0 或前一字符是 `\n`）且该段非空行 → 插入；
/// - 区间内每个 `\n` 之后（下一段非空行）→ 插入；
/// - 空行（`\n\n`）与 `\r` 起始行（CRLF 空行/孤立回车）不插入——空行插入
///   缩进会平白多出一行占位，破坏与裸文本排版的一致性；
/// - 只插入不删改：返回文本长度 ≥ 原区间长度，偏移坐标不受影响。
String txtDisplayText(
  String chapterText,
  int start,
  int end, {
  String indent = txtParagraphIndent,
}) {
  final raw = chapterText.substring(start, end);
  if (indent.isEmpty || start >= end) return raw;
  final buffer = StringBuffer();
  // 区间首段：段落首行且非空行才缩进（续页起点在段中则不缩进）。
  final atParagraphStart =
      start == 0 || chapterText.codeUnitAt(start - 1) == 0x0A;
  if (atParagraphStart && _paragraphHasContent(chapterText, start, end)) {
    buffer.write(indent);
  }
  for (var i = start; i < end; i++) {
    final unit = chapterText.codeUnitAt(i);
    buffer.writeCharCode(unit);
    if (unit == 0x0A &&
        i + 1 < end &&
        _paragraphHasContent(chapterText, i + 1, end)) {
      buffer.write(indent);
    }
  }
  return buffer.toString();
}

/// 段落首字符是否为可显示内容（`\n` 与 `\r` 视为空行/回车，不缩进）。
bool _paragraphHasContent(String text, int start, int end) {
  if (start >= end) return false;
  final first = text.codeUnitAt(start);
  return first != 0x0A && first != 0x0D;
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
    this.paragraphIndent = txtParagraphIndent,
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

  /// 段落首行缩进（A10；空串 = 不缩进）。
  final String paragraphIndent;

  /// 对齐方式（A10 两端对齐：渲染与测量同参数，见库注释结论）。
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
      // 上一页字符数作为本页二分探测提示（只影响搜索区间，不影响结果）。
      var hint = 512;
      while (start < length) {
        final fit = _findMaxFit(painter, request, start, hint);
        // 连 1 个字符都放不下（视口过小）：仍产出 1 字符页，保证推进
        // （极端情况下允许代理对跨页，换取必然终止）。
        final take = fit > 0 ? fit : 1;
        pages.add(TxtPageRange(start: start, end: start + take));
        hint = take;
        start += take;
      }
    } finally {
      painter.dispose();
    }
    return pages;
  }

  /// 二分查找从 [start] 起一页能容纳的最大字符数（返回 0 表示 1 字符也放不下）。
  ///
  /// 边界推进以 pivot（mid）为准而非边界修正后的实际尝试长度：代理对修正
  /// 会使实际尝试长度比 mid 短 1，若按它推进可能原地踏步（死循环）。
  static int _findMaxFit(
    TextPainter painter,
    TxtPaginationRequest request,
    int start,
    int hint,
  ) {
    final text = request.text;
    final remaining = text.length - start;
    var lo = 1;
    var hi = remaining;
    var best = 0;

    // 用提示值先探一次，把搜索区间收窄（只影响搜索区间，不影响结果）。
    if (hint > 1 && hint < remaining) {
      final probe = _tryFit(painter, request, text, start, start + hint);
      if (probe > 0) {
        best = probe - start;
        lo = hint + 1;
      } else {
        hi = hint - 1;
      }
    }

    while (lo <= hi) {
      final mid = lo + (hi - lo) ~/ 2;
      final end = _tryFit(painter, request, text, start, start + mid);
      if (end > 0) {
        best = end - start;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  /// 尝试排版 `text[start..endLimit)`；返回实际采用的区间终点
  ///（代理对边界修正后），放不下返回 0。
  ///
  /// 测量对象为 [txtDisplayText] 变换后的显示文本（含段落缩进），与渲染
  /// 视图共用同一变换——缩进字符参与排版，页内容不会因缩进而溢出。
  static int _tryFit(
    TextPainter painter,
    TxtPaginationRequest request,
    String text,
    int start,
    int endLimit,
  ) {
    final end = _boundaryEnd(text, start, endLimit);
    if (end <= start) return 0;
    painter.text = TextSpan(
      text: txtDisplayText(text, start, end, indent: request.paragraphIndent),
      style: TextStyle(
        fontSize: request.fontSize,
        height: request.lineHeight,
        fontFamily: request.fontFamily,
        fontFamilyFallback: request.fontFamilyFallback,
      ),
    );
    painter.textAlign = request.textAlign;
    painter.layout(maxWidth: request.viewportWidth);
    return painter.height <= request.viewportHeight + _heightEpsilon ? end : 0;
  }

  /// 页界避开代理对：`end-1` 是高代理且 `end` 是低代理时回退 1 位。
  static int _boundaryEnd(String text, int start, int end) {
    if (end <= start) return start;
    if (end > start && end < text.length) {
      final prev = text.codeUnitAt(end - 1);
      final next = text.codeUnitAt(end);
      if (prev >= 0xD800 &&
          prev <= 0xDBFF &&
          next >= 0xDC00 &&
          next <= 0xDFFF) {
        return end - 1;
      }
    }
    return end;
  }
}
