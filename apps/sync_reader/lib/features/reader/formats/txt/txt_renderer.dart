/// txt 渲染器（FR-202/FR-207 + v1.2 B1/B4/B5/B6）：双翻页模式 + 进度管线 +
/// 设置变更响应。
///
/// 组成：
/// - [TxtRenderer]：渲染会话。持有 [TxtBook]（解码+章节表）、当前逻辑位置
///   （章序号 + 章内字符偏移）、分页缓存与滚动度量；对宿主暴露
///   [TxtRenderer.applySettings]（设置变更入口，集成阶段由设置流驱动调用）。
/// - [TxtReaderController]：[ReaderController] 实现——restore 三分支
///   （docs/05 §3.3）、节流上报（500ms，∈250ms–1s）、jumpTo、同步 currentLocator。
/// - page 模式：PageView 翻页（B5：轴向随设置切换上下滑动/左右翻页），
///   分页内核为整行分页（B1：页界落在行边界，无半行），首屏只分页当前章
///   （isolate），章间经首尾"章间页"衔接；页码信息经
///   [ReaderPageInfoProvider.currentPageInfo] 供宿主底部控制条展示。
/// - scroll 模式：ListView.builder 按章分块惰性构建；滚动位置 → 当前章 =
///   视口顶部所在章，charOffset = 章内已滚过比例 × 章长（近似，见
///   [TxtRenderer.locateScrollOffset] 注释）。
/// - B6 文字探测：page/scroll 面板注册命中委托，宿主中区热区点击前询问
///   [ReaderTextProbe.isTextAt]（txt 为字形盒粒度，对齐原型 clickOnText）。
///
/// 排版（v1.1 A10 + v1.2 B4）：正文列宽上限 720（AppLayout.readerMaxWidth，
/// 居中）、衬线字体（Q2，经 resolveReaderFont）、段落首行缩进 2em（可关）+
/// 段距整行空行 + 两端对齐——分页测量与视图渲染共用 txt_paginator 的显示
/// 变换（txtDisplayText/txtPageDisplayText），见该文件头注释。
///
/// 主题：[TxtThemeColors.of] 映射背景/正文/辅助色，跟随设置即时生效。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;

import '../../../../core/design_tokens.dart' show AppLayout;
import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_controller.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import '../../reader_chrome.dart';
import '../../reader_indent.dart';
import 'txt_book_parser.dart';
import 'txt_chapter_anchor.dart';
import 'txt_locator.dart';
import 'txt_paginator.dart';
import 'txt_theme.dart';

/// 进度上报节流窗口（契约约定 250ms–1s 量级）。
const Duration txtProgressThrottle = Duration(milliseconds: 500);

/// txt 渲染会话。
class TxtRenderer extends BookRenderer
    implements ReaderPageInfoProvider, ReaderPercentJump, ReaderTextProbe {
  TxtRenderer._({
    required BookFile bookFile,
    required TxtBook initialBook,
    required ReaderSettings initialSettings,
  }) : file = bookFile,
       _book = initialBook,
       _settings = initialSettings {
    controller = TxtReaderController._(this);
  }

  /// 打开渲染会话：整书解码 + 切章（isolate）。初始位置由
  /// [TxtReaderController.restore] 决定（默认从第一章开始）。
  static Future<TxtRenderer> open({
    required BookFile file,
    required ReaderSettings settings,
  }) async {
    final bytes = await file.file.readAsBytes();
    final book = await TxtBook.parse(bytes, settings.txtEncodingOverride);
    return TxtRenderer._(
      bookFile: file,
      initialBook: book,
      initialSettings: settings,
    );
  }

  /// 正文文件（编码覆盖变更时按需重读，不长期持有字节缓存）。
  final BookFile file;

  TxtBook _book;
  ReaderSettings _settings;
  bool _disposed = false;

  /// 当前逻辑位置：章序号（0 起）。
  int _chapterIndex = 0;

  /// 当前逻辑位置：章内字符偏移（UTF-16 码元）。
  int _charOffset = 0;

  /// 视图重定位总线：restore/jumpTo/applySettings 后自增；视图监听它完成
  /// "外部重定位"（用户翻页/滚动不经此通道，避免回流循环）。
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// 分页缓存：章序号 → 页表 future（排版键变化时整体失效）。
  final Map<int, Future<List<TxtPageRange>>> _pageFutures = {};
  _LayoutKey? _layoutKey;

  /// scroll 模式度量：已构建章的实测高度 / 文档顶（滚动偏移坐标）。
  final Map<int, double> _scrollHeights = {};
  final Map<int, double> _scrollTops = {};

  // —— 学习到的"像素/字符"高度系数（0 = 未学习，用字号估算）——
  double _pxPerChar = 0;
  List<double>? _docTopCache;

  /// 音量键翻页委托（FR-209）：由当前激活的视图面板注册——page 模式驱动
  /// PageView 相邻页（含章间衔接），scroll 模式滚动一屏；参数 delta = +1
  /// 下一页 / -1 上一页。未挂视图（headless）时为 null，翻页返回 false。
  Future<bool> Function(int delta)? _turnDelegate;

  /// B6 文字命中委托：由当前激活的视图面板注册；视图未挂载为 null
  /// （[ReaderTextProbe.isTextAt] 返回 false → 中区点击视为空白）。
  bool Function(Offset globalPosition)? _textProbeDelegate;

  /// [ReaderTextProbe] 契约：转发当前面板的命中判定（B6 文字优先）。
  @override
  bool isTextAt(Offset globalPosition) {
    final probe = _textProbeDelegate;
    if (_disposed || probe == null) return false;
    return probe(globalPosition);
  }

  /// 当前章内页码信息（page 模式视图回报；scroll 模式/未就绪为 null）。
  (int, int)? _pageInfo;

  // —— 节流上报 ——
  Timer? _pendingReport;
  DateTime _lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 阅读控制器（宿主唯一交互面）。
  @override
  late final TxtReaderController controller;

  // —— 只读状态（集成/测试用）——

  /// 当前生效设置。
  ReaderSettings get settings => _settings;

  /// 当前章序号。
  int get positionChapter => _chapterIndex;

  /// 当前章内字符偏移。
  int get positionOffset => _charOffset;

  /// 实际解码编码名（编码覆盖切换后变化，测试与诊断用）。
  String get encodingName => _book.encodingName;

  /// 章节数。
  int get chapterCount => _book.chapters.length;

  /// 章题（下标钳制）。
  String chapterTitle(int index) =>
      _book.chapters[index.clamp(0, _book.chapters.length - 1)].title;

  /// 章内字符数（下标钳制）。
  int chapterCharLength(int index) =>
      _book.chapters[index.clamp(0, _book.chapters.length - 1)].length;

  /// 章全文（含章题行；下标钳制）。
  String chapterText(int index) {
    final chapter = _book.chapters[index.clamp(0, _book.chapters.length - 1)];
    return _book.text.substring(chapter.startOffset, chapter.endOffset);
  }

  /// 当前主题配色。
  TxtThemeColors get themeColors => TxtThemeColors.of(_settings.theme);

  /// 正文样式（字号/行距/字体/前景色随设置即时生效；衬线为默认，Q2）。
  TextStyle bodyTextStyle() {
    final font = resolveReaderFont(_settings.fontFamily);
    return TextStyle(
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
      fontFamily: font.family,
      fontFamilyFallback: font.fallback,
      color: themeColors.foreground,
    );
  }

  /// 视图重定位总线（面板内部消费）。
  ValueListenable<int> get revision => _revision;

  // —— 位置与进度 ——

  /// 当前全书进度 =（当前章之前字符总数 + 章内偏移）/ 全书字符数 ∈ [0,1]。
  double get percent =>
      TxtPercentMath.percentOf(_book.chapters, _chapterIndex, _charOffset);

  /// 当前逻辑位置快照（宿主退出/切后台时兜底落库用，同步返回，FR-207）。
  ProgressAnchor get currentLocator => ProgressAnchor(
    locatorJson: TxtLocator.encode(_chapterIndex, _charOffset),
    percent: percent,
    hasProgress: true,
  );

  void _setPosition(int chapterIndex, int charOffset) {
    _chapterIndex = chapterIndex.clamp(0, _book.chapters.length - 1);
    final len = _book.chapters[_chapterIndex].length;
    _charOffset = charOffset.clamp(0, len);
  }

  /// 视图层报告用户操作产生的位置变化（翻页/滚动），节流后上报宿主。
  void reportPosition(int chapterIndex, int charOffset) {
    if (_disposed) return;
    _setPosition(chapterIndex, charOffset);
    _scheduleProgressReport();
  }

  void _scheduleProgressReport() {
    if (_disposed || controller.onProgressChanged == null) return;
    if (_pendingReport != null) return; // 已有待发上报（合并高频滚动/翻页）
    final elapsed = DateTime.now().difference(_lastReportAt);
    if (elapsed >= txtProgressThrottle) {
      _fireProgressReport();
      return;
    }
    _pendingReport = Timer(txtProgressThrottle - elapsed, () {
      _pendingReport = null;
      if (!_disposed) _fireProgressReport();
    });
  }

  void _fireProgressReport() {
    _lastReportAt = DateTime.now();
    controller.onProgressChanged?.call(currentLocator, percent);
  }

  // —— 契约：restore / jumpTo ——

  /// 恢复进度（docs/05 §3.3 三分支）：
  /// 1. 无进度 → noProgress，开卷第一章首；
  /// 2. locator 非法（type 不符/字段缺失/负值/损坏 JSON）或章越界
  ///    → degradedToPercent，percent × 总字符映射到所在章的章首，
  ///      applied 的 locator 为空对象、percent 保持不变（契约约定）；
  /// 3. 合法 locator → exact，章内偏移钳制到章长。
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) {
    final ReaderRestoreResult result;
    if (!saved.hasProgress) {
      _setPosition(0, 0);
      result = const ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    } else {
      final anchor = TxtLocator.decode(saved.decodeLocator());
      if (anchor == null || anchor.chapterIndex >= _book.chapters.length) {
        final i = TxtPercentMath.chapterIndexAtPercent(
          _book.chapters,
          saved.percent,
        );
        _setPosition(i, 0);
        result = ReaderRestoreResult(
          mode: ReaderRestoreMode.degradedToPercent,
          applied: ProgressAnchor(
            locatorJson: '{}',
            percent: saved.percent,
            hasProgress: true,
          ),
        );
      } else {
        final off = anchor.charOffset.clamp(
          0,
          _book.chapters[anchor.chapterIndex].length,
        );
        _setPosition(anchor.chapterIndex, off);
        result = ReaderRestoreResult(
          mode: ReaderRestoreMode.exact,
          applied: ProgressAnchor(
            locatorJson: TxtLocator.encode(anchor.chapterIndex, off),
            percent: percent,
            hasProgress: true,
          ),
        );
      }
    }
    _bumpRevision();
    return Future.value(result);
  }

  /// 跳转到目录条目：anchor 必须是 [TxtChapterAnchor]（跳章首），否则忽略。
  Future<void> jumpToTocEntry(TocEntry entry) {
    final anchor = entry.anchor;
    if (anchor is TxtChapterAnchor) {
      _setPosition(anchor.chapterIndex, 0);
      _bumpRevision();
      _scheduleProgressReport();
    }
    return Future.value();
  }

  // —— 翻页（音量键翻页 FR-209，契约 nextPage/previousPage）——

  /// 翻到下一页：委托给激活面板执行（page 模式翻一页 / scroll 模式滚一屏，
  /// 机制见各面板 `_turnPage`）；视图未挂载（headless）或面板加载中返回 false。
  Future<bool> nextPage() => _turnPage(1);

  /// 翻到上一页：语义同 [nextPage]，方向相反。
  Future<bool> previousPage() => _turnPage(-1);

  Future<bool> _turnPage(int delta) {
    final delegate = _turnDelegate;
    if (_disposed || delegate == null) return Future.value(false);
    return delegate(delta);
  }

  // —— 页码信息与按比例跳转（v1.1 A8，契约外公开约定的能力接口）——

  /// 视图回报当前章内页码（page 模式面板调用；scroll 模式回报 null 清除）。
  ///
  /// 页码变化必须挂一次节流上报：宿主底部控制条的「本章 x / y 页」只在
  /// onProgressChanged 触发的 setState 里重读 [_pageInfo]——没有上报，
  /// 跳章/跳目录后的页码标签会一直停留在上一页（实测：跨章翻页后标签
  /// 停在「3 / 3」，正文已是下一章第 1 页）。
  void notePagePosition((int, int)? info) {
    if (_disposed) return;
    if (_pageInfo == info) return;
    _pageInfo = info;
    _scheduleProgressReport();
  }

  /// 当前章内页码（[ReaderPageInfoProvider] 契约）。
  @override
  (int, int)? get currentPageInfo => _disposed ? null : _pageInfo;

  /// 按全书比例跳转（[ReaderPercentJump] 契约；进度滑块用）：
  /// percent → 所在章的章首 + 章内按比例偏移（近似定位，与降级恢复的
  /// percent 语义一致），位置变化经 revision 驱动视图重载与节流上报。
  @override
  Future<void> jumpToPercent(double percent) async {
    if (_disposed) return;
    final i = TxtPercentMath.chapterIndexAtPercent(_book.chapters, percent);
    final chapter = _book.chapters[i.clamp(0, _book.chapters.length - 1)];
    final target = (percent.clamp(0.0, 1.0) * _book.totalChars).round();
    final offset = (target - chapter.startOffset).clamp(0, chapter.length);
    _setPosition(i, offset);
    _bumpRevision();
    _scheduleProgressReport();
  }

  /// 目录条目是否为当前章（[BookRenderer.isTocEntryCurrent] 契约）。
  @override
  bool isTocEntryCurrent(TocEntry entry) {
    final anchor = entry.anchor;
    return anchor is TxtChapterAnchor && anchor.chapterIndex == _chapterIndex;
  }

  void _bumpRevision() {
    if (!_disposed) _revision.value++;
  }

  // —— 设置变更（集成阶段入口）——

  /// 应用新设置（宿主监听设置仓库后调用；渲染器比较新旧值决定响应）：
  /// - 编码覆盖变更 → isolate 整书重解码重切章，按"章序号 + 章内比例"保留位置；
  /// - 排版变更（字号/行距/边距/字体/段距/首行缩进）→ 清分页与滚动度量
  ///   缓存，重排后按"当前章首字符偏移"重新定位（落章首，规格约定）；
  /// - 主题/翻页模式/翻页动画/夜间亮度 → 仅触发视图重建（配色/轴向/滤镜），
  ///   位置不变。
  Future<void> applySettings(ReaderSettings next) async {
    if (_disposed || next == _settings) return;
    final old = _settings;
    _settings = next;
    var relocated = false;

    if (next.txtEncodingOverride != old.txtEncodingOverride) {
      await _reloadBook();
      relocated = true;
    }

    final typographyChanged =
        next.fontSize != old.fontSize ||
        next.lineHeight != old.lineHeight ||
        next.pageMargin != old.pageMargin ||
        next.fontFamily != old.fontFamily ||
        next.paragraphGap != old.paragraphGap ||
        next.firstLineIndent != old.firstLineIndent;
    if (typographyChanged) {
      _pageFutures.clear();
      _scrollHeights.clear();
      _scrollTops.clear();
      _pxPerChar = 0;
      _docTopCache = null;
      // 规格约定：重排后按当前章首字符偏移重新定位（落章首）。
      _charOffset = 0;
      relocated = true;
    }

    _bumpRevision();
    if (relocated) _scheduleProgressReport();
  }

  /// 编码覆盖变更：重读文件 → isolate 重解码重切章 → 近似保留位置。
  Future<void> _reloadBook() async {
    final oldChapter = _book.chapterAt(_chapterIndex);
    final frac = oldChapter.length > 0 ? _charOffset / oldChapter.length : 0.0;
    final bytes = await file.file.readAsBytes();
    final book = await TxtBook.parse(bytes, _settings.txtEncodingOverride);
    if (_disposed) return;
    _book = book;
    // 编码重解码后字符坐标整体漂移：章序号保持、章内按比例近似映射。
    _chapterIndex = _chapterIndex.clamp(0, book.chapters.length - 1);
    final newLen = book.chapters[_chapterIndex].length;
    _charOffset = (frac * newLen).round().clamp(0, newLen);
    _pageFutures.clear();
    _scrollHeights.clear();
    _scrollTops.clear();
    _pxPerChar = 0;
    _docTopCache = null;
  }

  // —— 分页（page 模式面板消费）——

  /// 取某章页表（缓存 + isolate 计算；排版键变化自动失效）。
  ///
  /// 测量参数与视图渲染严格一致：衬线字体栈（Q2）、段落首行缩进 2em
  /// （B4 可关）、段距整行空行（B4）+ 两端对齐（A10，见 txt_paginator
  /// 库注释）。
  Future<List<TxtPageRange>> ensurePages(int chapterIndex, Size contentSize) {
    if (_disposed) return Future.value(const []);
    final key = _LayoutKey(
      fontSize: _settings.fontSize,
      lineHeight: _settings.lineHeight,
      fontFamily: _settings.fontFamily,
      paragraphGapLines: _settings.paragraphGap.lines,
      firstLineIndent: _settings.firstLineIndent,
      width: contentSize.width,
      height: contentSize.height,
    );
    if (_layoutKey != key) {
      _pageFutures.clear();
      _layoutKey = key;
    }
    final i = chapterIndex.clamp(0, _book.chapters.length - 1);
    return _pageFutures.putIfAbsent(i, () {
      final chapter = _book.chapters[i];
      final font = resolveReaderFont(_settings.fontFamily);
      final request = TxtPaginationRequest(
        text: _book.text.substring(chapter.startOffset, chapter.endOffset),
        fontSize: _settings.fontSize,
        lineHeight: _settings.lineHeight,
        fontFamily: font.family,
        fontFamilyFallback: font.fallback,
        indentEm: _settings.firstLineIndent ? kReaderParagraphIndentEm : 0,
        paragraphGapLines: _settings.paragraphGap.lines,
        textAlign: TextAlign.justify,
        viewportWidth: contentSize.width,
        viewportHeight: contentSize.height,
      );
      return TxtPaginator.paginate(request);
    });
  }

  // —— 滚动度量（scroll 模式面板消费）——

  /// 章内容项构建后回报实测高度与文档顶（docTop = 滚动偏移坐标）。
  void noteScrollItemMetrics(
    int chapterIndex, {
    required double height,
    required double topDoc,
  }) {
    if (_disposed) return;
    final changed = _scrollHeights[chapterIndex] != height;
    _scrollHeights[chapterIndex] = height;
    _scrollTops[chapterIndex] = topDoc;
    final len = chapterCharLength(chapterIndex);
    if (len > 0) {
      // 指数滑动平均逼近真实排版密度（首测直接采用）。
      final ratio = height / len;
      _pxPerChar = _pxPerChar <= 0 ? ratio : _pxPerChar * 0.7 + ratio * 0.3;
    }
    if (changed) _docTopCache = null;
  }

  /// 未构建章的高度估算基础：像素/字符系数（实测 EMA 优先，字号估算兜底）。
  double pixelsPerCharEstimate(double contentWidth) {
    if (_pxPerChar > 0) return _pxPerChar;
    final charsPerLine = math.max(1.0, contentWidth / _settings.fontSize);
    // CJK 方块字近似：每行 charsPerLine 字，每字高 fontSize×lineHeight。
    return _settings.fontSize * _settings.lineHeight / charsPerLine;
  }

  double _chapterHeight(int i, double pxPerChar) =>
      _scrollHeights[i] ?? chapterCharLength(i) * pxPerChar;

  /// 章顶文档坐标表（估算高度前缀和，实测高度参与；缓存至度量/排版变化）。
  List<double> docTopTable(double pxPerChar) {
    final cached = _docTopCache;
    if (cached != null && cached.length == _book.chapters.length) return cached;
    final tops = List<double>.filled(_book.chapters.length, 0);
    var acc = 0.0;
    for (var i = 0; i < tops.length; i++) {
      tops[i] = acc;
      acc += _chapterHeight(i, pxPerChar);
    }
    _docTopCache = tops;
    return tops;
  }

  /// 滚动偏移 → 逻辑位置。
  ///
  /// 近似约定（规格允许）：当前章 = 视口顶部所在章；charOffset =
  /// (视口顶深入该章的像素 / 该章像素高) × 章长。章高优先用实测值，
  /// 未构建章用像素/字符估算——滚动中章内 charOffset 存在少量漂移，
  /// 章粒度始终准确。
  (int, int) locateScrollOffset(double scrollOffset, double pxPerChar) {
    final tops = docTopTable(pxPerChar);
    if (tops.isEmpty) return (0, 0);
    var lo = 0;
    var hi = tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (tops[mid] <= scrollOffset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final height = _chapterHeight(lo, pxPerChar);
    final frac = height > 0
        ? ((scrollOffset - tops[lo]) / height).clamp(0.0, 1.0)
        : 0.0;
    final len = chapterCharLength(lo);
    return (lo, (frac * len).round().clamp(0, len));
  }

  /// 章顶文档坐标（跳章定位用；有实测 top 时直接采用）。
  double estimateScrollTop(int chapterIndex, double pxPerChar) {
    final measured = _scrollTops[chapterIndex];
    if (measured != null) return measured;
    final tops = docTopTable(pxPerChar);
    return tops[chapterIndex.clamp(0, tops.length - 1)];
  }

  /// 章高（实测优先，估算兜底）。
  double estimateScrollHeight(int chapterIndex, double pxPerChar) =>
      _chapterHeight(chapterIndex, pxPerChar);

  // —— 契约：视图与销毁 ——

  @override
  Widget buildView(BuildContext context) => _TxtViewHost(renderer: this);

  @override
  void dispose() {
    _disposed = true;
    _pendingReport?.cancel();
    _pendingReport = null;
    // 刻意不 dispose _revision：宿主先 dispose 渲染器、后拆卸视图树时视图
    // 仍短暂持有监听；ValueNotifier 无需显式释放，随渲染器 GC。
    controller.dispose();
  }
}

/// 分页缓存键：排版要素 + 视口尺寸任一变化即失效（B4：段距/缩进参与）。
class _LayoutKey {
  const _LayoutKey({
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.paragraphGapLines,
    required this.firstLineIndent,
    required this.width,
    required this.height,
  });

  final double fontSize;
  final double lineHeight;
  final String? fontFamily;
  final int paragraphGapLines;
  final bool firstLineIndent;
  final double width;
  final double height;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _LayoutKey &&
          fontSize == other.fontSize &&
          lineHeight == other.lineHeight &&
          fontFamily == other.fontFamily &&
          paragraphGapLines == other.paragraphGapLines &&
          firstLineIndent == other.firstLineIndent &&
          width == other.width &&
          height == other.height;

  @override
  int get hashCode => Object.hash(
    fontSize,
    lineHeight,
    fontFamily,
    paragraphGapLines,
    firstLineIndent,
    width,
    height,
  );
}

// ============================================================================
// 控制器
// ============================================================================

/// [ReaderController] 的 txt 实现，全部转发渲染会话。
class TxtReaderController extends ReaderController {
  TxtReaderController._(this._r);

  final TxtRenderer _r;

  // onProgressChanged 继承自 ReaderController 的实例字段，直接赋值即可。

  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) =>
      _r.restore(saved);

  @override
  ProgressAnchor get currentLocator => _r.currentLocator;

  @override
  double get percent => _r.percent;

  @override
  Future<void> jumpTo(TocEntry entry) => _r.jumpToTocEntry(entry);

  @override
  Future<bool> nextPage() => _r.nextPage();

  @override
  Future<bool> previousPage() => _r.previousPage();

  @override
  void dispose() {
    onProgressChanged = null;
    _r._pendingReport?.cancel();
    _r._pendingReport = null;
  }
}

// ============================================================================
// 视图
// ============================================================================

/// 视图宿主：背景色随主题，LayoutBuilder 提供内容区，按翻页模式选面板。
///
/// 正文列宽上限 [AppLayout.readerMaxWidth]（720，A10）：宽屏时内容列居中，
/// 窄屏时退化为「视口宽 - 2×页边距」。两个尺寸（列宽/列高）同时传给
/// 分页器与视图，保证测量与渲染一致。
class _TxtViewHost extends StatelessWidget {
  const _TxtViewHost({required this.renderer});

  final TxtRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: renderer.revision,
      builder: (context, _, _) {
        final colors = renderer.themeColors;
        return Container(
          color: colors.background,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final margin = renderer.settings.pageMargin;
              final columnWidth = math.min(
                AppLayout.readerMaxWidth,
                math.max(0.0, constraints.maxWidth - margin * 2),
              );
              final content = Size(
                columnWidth,
                math.max(0.0, constraints.maxHeight - margin * 2),
              );
              final isPage = renderer.settings.pageMode == ReaderPageMode.page;
              final horizontalInset = (constraints.maxWidth - columnWidth) / 2;
              return KeyedSubtree(
                key: ValueKey(isPage ? 'txt-page-mode' : 'txt-scroll-mode'),
                child: isPage
                    ? _TxtPagePane(renderer: renderer, content: content)
                    : _TxtScrollPane(
                        renderer: renderer,
                        content: content,
                        horizontalInset: horizontalInset,
                      ),
              );
            },
          ),
        );
      },
    );
  }
}

/// B6 共享命中判定：[renderObject]（应为正文段落的 [RenderParagraph]）在
/// 全局坐标 [global] 处是否画有文字（±4px 容差，对齐原型 clickOnText 的
/// 「行内盒命中 + 余量」行为）。
///
/// 做法：先把点换算到段落本地坐标，用 `getPositionForOffset` 取最近字符，
/// 再查该字符的字形盒是否包含该点——空行/页边空白/行间空白处最近字符的
/// 字形盒不包含点击点，判为非文字。O(1) 查询，与文本长度无关。
bool _hitTestParagraph(RenderObject? renderObject, Offset global) {
  if (renderObject is! RenderParagraph || !renderObject.attached) return false;
  final box = renderObject;
  if (!box.hasSize || box.size.isEmpty) return false;
  final local = box.globalToLocal(global);
  if (local.dx < -4 ||
      local.dy < -4 ||
      local.dx > box.size.width + 4 ||
      local.dy > box.size.height + 4) {
    return false;
  }
  final plain = box.text.toPlainText();
  if (plain.isEmpty) return false;
  final position = box.getPositionForOffset(local);
  final boxes = box.getBoxesForSelection(
    TextSelection(baseOffset: position.offset, extentOffset: position.offset),
  );
  for (final glyph in boxes) {
    if (local.dx >= glyph.left - 4 &&
        local.dx <= glyph.right + 4 &&
        local.dy >= glyph.top - 2 &&
        local.dy <= glyph.bottom + 2) {
      return true;
    }
  }
  return false;
}

/// page 模式面板：单章 PageView + 章间衔接（页码/进度由宿主控制条承载）。
///
/// PageView itemCount = 章页数 + 2：首尾各一"章间页"，滑入即切换到相邻章
/// （下一章落章首 / 上一章落末页），页表在 isolate 计算期间显示加载态。
/// B5/v1.3.7：轴向**按设备形态自动选**（窄视口 = 横轴左右翻页，宽视口 =
/// 纵轴），委托翻页走 animateToPage 播放推移动画；**鼠标拖动翻页已禁用**
/// （见 [kReaderTouchOnlyDragDevices]），触摸滑动翻页由 PageView 原生手势承担。
/// 分页模式下滚轮被**吞掉**（见 [_TxtPagePaneState._swallowWheel]）：
/// 翻页只由键盘与触摸滑动控制（v1.3.7 用户决定）。
/// 视口尺寸变化防抖 150ms 后整章重分页（否则旧页表在新视口上出现半行）。
class _TxtPagePane extends StatefulWidget {
  const _TxtPagePane({required this.renderer, required this.content});

  final TxtRenderer renderer;
  final Size content;

  @override
  State<_TxtPagePane> createState() => _TxtPagePaneState();
}

class _TxtPagePaneState extends State<_TxtPagePane> {
  /// 翻页动画时长（原型 TURN_MS = 340ms 的就近取整）。
  static const Duration _turnDuration = Duration(milliseconds: 300);

  int _pagesChapter = -1;
  int _syncedOffset = -1;
  List<TxtPageRange>? _pages;
  String _chapterText = '';
  PageController? _pageCtrl;
  bool _switching = false;

  /// 页面正文渲染盒的 Key（按全局页下标；B6 文字命中探测用）。
  final Map<int, GlobalKey> _pageTextKeys = {};

  /// 章加载代数：丢弃过期的分页结果（连续切章/改排版/改视口尺寸时，
  /// 先前发出的分页 future 不得覆盖最新状态）。
  int _loadGeneration = 0;

  /// 视口尺寸变化防抖：拖拽缩放窗口时 LayoutBuilder 每帧改尺寸，逐帧
  /// 整章重分页会刷爆 isolate；静默 150ms 后一次性重载。
  Timer? _resizeDebounce;

  /// 首帧已画出：[[_loadChapter]] 首次经 initState 链调用，不得 setState。
  bool _shownOnce = false;

  @override
  void initState() {
    super.initState();
    // 注册音量键翻页委托（FR-209）：page 模式驱动 PageView 相邻页。
    widget.renderer._turnDelegate = _turnPage;
    // 注册文字命中委托（B6）：当前页正文的字形盒粒度判定。
    widget.renderer._textProbeDelegate = _probeText;
    _syncWithRenderer();
  }

  @override
  void didUpdateWidget(_TxtPagePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content != oldWidget.content) {
      // 视口尺寸变化：旧页表按旧尺寸分页，继续用会出现半行——页内容
      // 高度超出新视口被页缘裁掉一行（实测：缩窗后页尾整行被拦腰切断）。
      // 防抖后按当前渲染器位置整章重载（新尺寸的 ensurePages 自动失效
      // 旧缓存并重分页）。
      _resizeDebounce?.cancel();
      final chapter = widget.renderer.positionChapter;
      final offset = widget.renderer.positionOffset;
      _resizeDebounce = Timer(const Duration(milliseconds: 150), () {
        if (mounted) _loadChapter(chapter, landingOffset: offset);
      });
      return;
    }
    _syncWithRenderer();
  }

  /// 与渲染器逻辑位置对齐：章变化或外部重定位（revision 自增）时重载。
  void _syncWithRenderer() {
    final r = widget.renderer;
    final chapter = r.positionChapter;
    final offset = r.positionOffset;
    if (_switching) return;
    if (_pages != null && _pagesChapter == chapter) {
      if (_syncedOffset == offset) return; // 位置未变（如纯主题切换）
      // 同章内重定位：跳到包含目标偏移的页（+1 前导章间页）。
      _syncedOffset = offset;
      _pageCtrl?.dispose();
      _pageCtrl = PageController(
        initialPage: TxtPaginator.pageIndexOf(_pages!, offset) + 1,
      );
      setState(() {});
      return;
    }
    _loadChapter(chapter, landingOffset: offset);
  }

  /// 加载章页表并重建 PageController（[landingOffset] 决定首屏页）。
  void _loadChapter(int chapter, {required int landingOffset}) {
    final r = widget.renderer;
    _resizeDebounce?.cancel();
    _resizeDebounce = null;
    _switching = true;
    _pagesChapter = chapter;
    _syncedOffset = landingOffset;
    _pages = null;
    _chapterText = r.chapterText(chapter);
    _pageTextKeys.clear(); // 章切换后旧页渲染盒全部失效
    // 立即切到加载态：否则上一视图（如章间页图标）会一直挂到分页完成，
    // 表现为「跨章后长时间停在只有图标的空白页」。
    if (_shownOnce) setState(() {});
    final gen = ++_loadGeneration;
    r.ensurePages(chapter, widget.content).then((pages) {
      if (gen != _loadGeneration) return; // 过期加载：章/尺寸又被改变了
      if (!mounted || r._disposed) return;
      if (r.positionChapter != _pagesChapter) {
        // 加载期间位置又被外部改变（restore/jumpTo）：释放加载态并重新对齐。
        setState(() => _switching = false);
        _syncWithRenderer();
        return;
      }
      setState(() {
        _pages = pages;
        _pageCtrl?.dispose();
        // keepPage 必须关掉：PageStorage 按 Scrollable 槽位存取页号，会
        // 用**旧**页号覆盖新控制器的 initialPage（跳章/跳目录/缩放重载后
        // 实测复现：显示页与控制器页失同步、同章跳章首不生效）。
        _pageCtrl = PageController(
          keepPage: false,
          initialPage: TxtPaginator.pageIndexOf(pages, landingOffset) + 1,
        );
        _switching = false;
      });
      final int target = TxtPaginator.pageIndexOf(pages, landingOffset) + 1;
      // keepPage 的 PageStorage 会按 Scrollable 槽位恢复**旧**页号，盖掉
      // 新控制器的 initialPage（实测：缩放重载后落在章间页图标上）；挂载
      // 后显式对齐一次，保证首屏就是 landingOffset 所在页。控制器实例若
      // 已被更新的加载替换（identical 不成立），本次对齐作废。
      final PageController ctrl = _pageCtrl!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_pageCtrl, ctrl) || !ctrl.hasClients) {
          return;
        }
        if ((ctrl.page ?? target.toDouble()) != target) {
          ctrl.jumpToPage(target);
        }
      });
      // 页码信息回报（宿主底部控制条「第 x / y 页」）。
      r.notePagePosition((target - 1, pages.length));
    });
  }

  /// 章间切换（滑入首尾章间页触发）；delta = -1 上一章 / +1 下一章。
  void _goRelativeChapter(int delta) {
    if (_switching || _pages == null) return;
    final r = widget.renderer;
    final target = _pagesChapter + delta;
    if (target < 0 || target >= r.chapterCount) {
      // 已是边界章：弹回真实页区。
      _pageCtrl?.jumpToPage(delta < 0 ? 1 : _pages!.length);
      return;
    }
    // 下一章落章首（偏移 0）；上一章落末页（偏移=章长 → 定位到末页）。
    final landingOffset = delta > 0 ? 0 : r.chapterCharLength(target);
    _loadChapter(target, landingOffset: landingOffset);
    r.reportPosition(target, landingOffset);
  }

  void _onPageChanged(int globalIndex) {
    final pages = _pages;
    if (pages == null || _switching) return;
    if (globalIndex == 0) {
      _goRelativeChapter(-1);
      return;
    }
    if (globalIndex == pages.length + 1) {
      _goRelativeChapter(1);
      return;
    }
    _syncedOffset = pages[globalIndex - 1].start;
    setState(() {}); // 刷新页码回报
    widget.renderer.notePagePosition((globalIndex - 1, pages.length));
    widget.renderer.reportPosition(_pagesChapter, _syncedOffset);
  }

  /// 音量键翻页委托（FR-209）：delta = +1 下一页 / -1 上一页。
  ///
  /// 跳相邻全局页（含滑入首尾章间页触发章间衔接，复用 [_onPageChanged]
  /// 的位置上报）；animateToPage 播放推移动画（B5），连按由 PageView
  /// 重定向到新目标。已在全书画廊边界（首章首页向前 / 末章末页向后）
  /// 返回 false 不动。
  Future<bool> _turnPage(int delta) async {
    final pages = _pages;
    final ctrl = _pageCtrl;
    if (pages == null || ctrl == null || _switching) return false;
    // 首帧构建时 PageView 尚未 attach：页码取语义值 1（与页脚读取一致）。
    // 布局未就绪（hasContentDimensions false）时 page 不可信：放弃本次
    // 翻页（等下一次滚动），避免按错误的当前页算目标导致来回弹。
    if (!ctrl.hasClients || !ctrl.position.hasContentDimensions) return false;
    final global = ctrl.page?.round();
    if (global == null) return false;
    final atBookStart = _pagesChapter == 0 && global <= 1;
    final atBookEnd =
        _pagesChapter == widget.renderer.chapterCount - 1 &&
        global >= pages.length;
    if ((delta < 0 && atBookStart) || (delta > 0 && atBookEnd)) {
      return false; // 已是全书边界，无实际移动
    }
    final target = (global + delta).clamp(0, pages.length + 1);
    if (ctrl.hasClients) {
      unawaited(
        ctrl
            .animateToPage(
              target,
              duration: _turnDuration,
              curve: Curves.easeOutCubic,
            )
            .catchError((_) {}),
      );
    }
    return true;
  }

  /// B6 文字命中判定：点击点是否落在当前页正文的字形盒上（±4px 容差，
  /// 对齐原型 clickOnText 的行内盒判定 + 4px 余量）。
  bool _probeText(Offset global) {
    final ctrl = _pageCtrl;
    if (ctrl == null || !ctrl.hasClients) return false;
    final current = ctrl.page?.round();
    if (current == null) return false;
    final context = _pageTextKeys[current]?.currentContext;
    if (context == null) return false;
    return _hitTestParagraph(context.findRenderObject(), global);
  }

  /// 分页模式：**吞掉滚轮事件**（不翻页，正文也不因滚轮而动）。
  ///
  /// v1.3.7：分页模式的翻页**只由键盘**（↑/↓/PageUp/PageDown/空格）与
  /// **触摸滑动**控制——滚轮在分页模式下既不翻页也不滚动（用户实测：分页模式
  /// 下用滚轮会乱翻）。
  ///
  /// 必须挂在**每个页项内部**而不能包在 PageView 外面：滚轮经
  /// PointerSignalResolver 分发，采用**最深（最先注册）**的回调——页项内部
  /// 比 PageView 的 Scrollable 更深，这里抢先注册后 Scrollable 的滚轮注册
  /// 失效，PageView 不再收到滚轮（否则桌面端竖轴 PageView 会被滚轮推动）。
  void _swallowWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      // 标记事件已处理：Scrollable 不得再用滚轮滚动正文。
      (event as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
  }

  @override
  Widget build(BuildContext context) {
    _shownOnce = true;
    final colors = widget.renderer.themeColors;
    final pages = _pages;
    final pageCtrl = _pageCtrl;
    final margin = widget.renderer.settings.pageMargin;
    // 翻页方向（v1.3.7）：**按设备形态自动选**，不再作为用户选项——
    // 移动端（窄视口 ≤460）用横轴（左右翻页的翻书手感）；
    // 桌面端用纵轴（正文纵向排版，纵轴翻页与阅读方向一致）。
    final narrow = MediaQuery.sizeOf(context).width <= kReaderNarrowBreakpoint;
    final axis = narrow ? Axis.horizontal : Axis.vertical;
    // 分页模式：**不接受鼠标拖动**（见 [kReaderTouchOnlyDragDevices]）——
    // 鼠标拖动翻页与滚轮一样会打乱页界；触摸滑动与键盘照常。
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: kReaderTouchOnlyDragDevices,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: margin),
        child: (pageCtrl == null || pages == null)
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : PageView.builder(
              controller: pageCtrl,
              scrollDirection: axis,
              itemCount: pages.length + 2,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, global) {
                // 页项内的 Listener 抢注滚轮事件（见 _swallowWheel 注释）：
                // 分页模式下滚轮被吞掉（不翻页、不滚动）；opaque 让页边空白
                // 处也命中。
                return Listener(
                  onPointerSignal: _swallowWheel,
                  behavior: HitTestBehavior.opaque,
                  child: (global == 0 || global == pages.length + 1)
                      ? Center(
                          child: Icon(
                            Icons.auto_stories_outlined,
                            color: colors.dim,
                          ),
                        )
                      : ClipRect(
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: SizedBox(
                              width: widget.content.width,
                              child: Text.rich(
                                // 与分页器同一显示变换（缩进/段距）+ 页尾分页符
                                // 不渲染空行盒（txtPageDisplaySpan，B1）。
                                txtPageDisplaySpan(
                                  _chapterText,
                                  pages[global - 1].start,
                                  pages[global - 1].end,
                                  style: widget.renderer.bodyTextStyle(),
                                  fontSize: widget.renderer.settings.fontSize,
                                  indentEm: widget
                                          .renderer.settings.firstLineIndent
                                      ? kReaderParagraphIndentEm
                                      : 0,
                                  paragraphGapLines: widget
                                      .renderer.settings.paragraphGap.lines,
                                ),
                                key: _pageTextKeys.putIfAbsent(
                                  global,
                                  GlobalKey.new,
                                ),
                                textAlign: TextAlign.justify,
                              ),
                            ),
                          ),
                        ),
                );
              },
            ),
      ),
    );
  }

  @override
  void dispose() {
    if (identical(widget.renderer._turnDelegate, _turnPage)) {
      widget.renderer._turnDelegate = null;
    }
    if (identical(widget.renderer._textProbeDelegate, _probeText)) {
      widget.renderer._textProbeDelegate = null;
    }
    _resizeDebounce?.cancel();
    _resizeDebounce = null;
    _pageCtrl?.dispose();
    super.dispose();
  }
}

/// scroll 模式面板：按章分块惰性构建 + 滚动位置 → 逻辑位置。
class _TxtScrollPane extends StatefulWidget {
  const _TxtScrollPane({
    required this.renderer,
    required this.content,
    required this.horizontalInset,
  });

  final TxtRenderer renderer;
  final Size content;

  /// 内容列相对视口的水平留白（宽屏 = (视口宽-720)/2，窄屏 = 页边距）。
  final double horizontalInset;

  @override
  State<_TxtScrollPane> createState() => _TxtScrollPaneState();
}

class _TxtScrollPaneState extends State<_TxtScrollPane> {
  ScrollController? _ctrl;
  int _syncedChapter = -1;
  int _syncedOffset = -1;
  int _locateAttempts = 0;

  /// 各章正文的渲染盒 Key（B6 文字命中探测用；仅已构建章有 context）。
  final Map<int, GlobalKey> _scrollTextKeys = {};

  /// 程序化定位中：抑制滚动回调的近似位置上报，避免覆盖精确恢复值。
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    // 注册音量键翻页委托（FR-209）：scroll 模式滚动一屏。
    widget.renderer._turnDelegate = _turnPage;
    // 注册文字命中委托（B6）：可见章正文的字形盒粒度判定。
    widget.renderer._textProbeDelegate = _probeText;
    // scroll 模式无页码概念：清除 page 模式可能残留的回报。
    widget.renderer.notePagePosition(null);
    final r = widget.renderer;
    _syncedChapter = r.positionChapter;
    _syncedOffset = r.positionOffset;
    // 初始偏移用估算表（首帧前无实测度量），构建后由 _locateRendererPosition 校正。
    _ctrl = ScrollController(
      initialScrollOffset: _estimateTop(r.positionChapter, r.positionOffset),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _locateRendererPosition(),
    );
  }

  /// B6 文字命中判定：点击点是否落在任一已构建章正文的字形盒上。
  bool _probeText(Offset global) {
    for (final key in _scrollTextKeys.values) {
      final hit = _hitTestParagraph(key.currentContext?.findRenderObject(), global);
      if (hit) return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(_TxtScrollPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final r = widget.renderer;
    // 外部重定位（restore/jumpTo/设置重排）→ 重新滚动定位。
    if (r.positionChapter != _syncedChapter ||
        r.positionOffset != _syncedOffset) {
      _locateRendererPosition();
    }
  }

  double _pxPerChar() =>
      widget.renderer.pixelsPerCharEstimate(widget.content.width);

  double _estimateTop(int chapter, int offset) {
    final r = widget.renderer;
    final pxPerChar = _pxPerChar();
    final tops = r.docTopTable(pxPerChar);
    final i = chapter.clamp(0, tops.length - 1);
    final height = r.estimateScrollHeight(i, pxPerChar);
    final len = r.chapterCharLength(i);
    final frac = len > 0 ? offset / len : 0.0;
    return tops[i] + frac * height;
  }

  /// 滚动到渲染器当前逻辑位置（restore/jumpTo/设置重排后调用）。
  ///
  /// 先按估算表跳转（章粒度准），目标章构建后用实测 top 校正估算误差
  /// （至多 3 轮，每轮等一帧）。
  void _locateRendererPosition() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.hasClients) {
      if (_locateAttempts++ < 10) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => mounted ? _locateRendererPosition() : null,
        );
      }
      return;
    }
    _locateAttempts = 0;
    _locating = true;
    final r = widget.renderer;
    final chapter = r.positionChapter;
    final offset = r.positionOffset;
    _syncedChapter = chapter;
    _syncedOffset = offset;
    final len = r.chapterCharLength(chapter);
    final frac = len > 0 ? offset / len : 0.0;

    void jumpTo(double target) =>
        ctrl.jumpTo(target.clamp(0.0, ctrl.position.maxScrollExtent));

    jumpTo(_estimateTop(chapter, offset));
    var corrections = 0;
    void correct() {
      corrections++;
      if (!mounted || corrections > 3) {
        _locating = false;
        return;
      }
      final measuredTop = r._scrollTops[chapter];
      final measuredHeight = r._scrollHeights[chapter];
      if (measuredTop == null ||
          measuredHeight == null ||
          measuredHeight <= 0) {
        // 目标章尚未构建（估算偏差较大）：再等一帧。
        WidgetsBinding.instance.addPostFrameCallback((_) => correct());
        return;
      }
      final delta = measuredTop + frac * measuredHeight - ctrl.offset;
      if (delta.abs() > 2) {
        jumpTo(ctrl.offset + delta);
        WidgetsBinding.instance.addPostFrameCallback((_) => correct());
        return;
      }
      _locating = false;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => correct());
  }

  void _onScroll() {
    if (_locating) return; // 定位产生的滚动不回写位置
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.hasClients) return;
    final r = widget.renderer;
    final (chapter, offset) = r.locateScrollOffset(ctrl.offset, _pxPerChar());
    _syncedChapter = chapter;
    _syncedOffset = offset;
    r.reportPosition(chapter, offset);
  }

  /// 音量键翻页委托（FR-209）：delta = +1 下一页 / -1 上一页，滚动一屏
  /// （视口高度），clamp 到文档端头；已在端头（无实际位移）返回 false。
  Future<bool> _turnPage(int delta) async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.hasClients) return false;
    final position = ctrl.position;
    final target = (ctrl.offset + delta * position.viewportDimension).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if ((target - ctrl.offset).abs() < 0.5) return false; // 已在文档端头
    ctrl.jumpTo(target);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.renderer;
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        _onScroll();
        return false;
      },
      child: ListView.builder(
        controller: _ctrl,
        padding: EdgeInsets.symmetric(
          horizontal: widget.horizontalInset,
          vertical: r.settings.pageMargin,
        ),
        itemCount: r.chapterCount,
        itemBuilder: (context, index) => _ScrollChapterItem(
          renderer: r,
          chapterIndex: index,
          textKey: _scrollTextKeys.putIfAbsent(index, GlobalKey.new),
        ),
      ),
    );
  }

  @override
  void dispose() {
    if (identical(widget.renderer._turnDelegate, _turnPage)) {
      widget.renderer._turnDelegate = null;
    }
    if (identical(widget.renderer._textProbeDelegate, _probeText)) {
      widget.renderer._textProbeDelegate = null;
    }
    _ctrl?.dispose();
    super.dispose();
  }
}

/// 单章内容项：章题 + 正文，构建后向渲染器回报实测度量（惰性构建单元）。
class _ScrollChapterItem extends StatefulWidget {
  const _ScrollChapterItem({
    required this.renderer,
    required this.chapterIndex,
    required this.textKey,
  });

  final TxtRenderer renderer;
  final int chapterIndex;

  /// 正文渲染盒 Key（B6 命中探测）。
  final GlobalKey textKey;

  @override
  State<_ScrollChapterItem> createState() => _ScrollChapterItemState();
}

class _ScrollChapterItemState extends State<_ScrollChapterItem> {
  double? _lastReportedHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  /// 实测章项高度与文档顶，回报渲染器（用于章定位与高度估算学习）。
  void _measure() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if (_lastReportedHeight == box.size.height) return;
    _lastReportedHeight = box.size.height;
    final scrollable = Scrollable.of(context);
    final scrollBox = scrollable.context.findRenderObject() as RenderBox?;
    var topDoc = 0.0;
    if (scrollBox != null) {
      // dy = 章项顶相对视口顶的距离；加当前滚动偏移得文档坐标。
      final dy = box.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
      final ctrl = scrollable.widget.controller;
      final offset = ctrl != null && ctrl.hasClients ? ctrl.offset : 0.0;
      topDoc = offset + dy;
    }
    widget.renderer.noteScrollItemMetrics(
      widget.chapterIndex,
      height: box.size.height,
      topDoc: topDoc,
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.renderer;
    final chapterText = r.chapterText(widget.chapterIndex);
    final settings = r.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 与分页器同一显示变换（章题样式/缩进/段距）+ 两端对齐（A10/B4）。
        //
        // 章题**不再单独渲染**：章题就是章的首行，由显示变换按标题样式
        // （1.32em / 600）渲染——此前单独渲染一次 + 正文里再渲染一次，
        // 滚动模式下章题会重复出现两遍。
        Text.rich(
          txtDisplaySpan(
            chapterText,
            0,
            chapterText.length,
            style: r.bodyTextStyle(),
            fontSize: settings.fontSize,
            indentEm: settings.firstLineIndent ? kReaderParagraphIndentEm : 0,
            paragraphGapLines: settings.paragraphGap.lines,
          ),
          key: widget.textKey,
          textAlign: TextAlign.justify,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
