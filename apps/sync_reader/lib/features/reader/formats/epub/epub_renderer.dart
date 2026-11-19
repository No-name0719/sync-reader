/// epub 渲染器（FR-203）：块化 HtmlWidget 渲染 + 双翻页模式 + 进度管线 + 恢复。
///
/// 组成：
/// - [EpubRenderer]：渲染会话。open 时整书解析（spine → XHTML → 块，图片
///   解析期替换为 data URI），解析结果缓存在实例内（翻页模式切换不重解析）；
///   对宿主暴露 [EpubRenderer.applySettings]（设置热应用入口，经 dynamic 调用）。
/// - [EpubReaderController]：[ReaderController] 实现——restore 三分支
///   （docs/05 §3.3）、3s 节流上报、jumpTo、同步 currentLocator。
/// - 双模式（ReaderSettings.pageMode）：scroll = 滚动（连续，不吸附）；
///   page = **同一连续内容** + **行边界页停**吸附翻页（[EpubPageScrollPhysics]
///   + 视口按页停裁剪）：页界落在行与行之间，正文行与章题都不会被拦腰切断
///   （旧实现按视口高整数倍吸附 → 页界落在行中间，是本缺陷的成因）。
/// - 进度管线：滚动监听 → 首个可见块（视口顶所在块）+ 块内像素比例 × 块长
///   → percent =（块前累计字符 + 块内偏移）/ 全书总字符 → 节流 3s 上报
///   （照抄 txt 的节流结构）。
///
/// 恢复（docs/05 §3.3）：exact = spineIndex 界内 + href 归一化匹配 +
/// blockIndex 界内 → 滚到块顶、块内按字符比例估偏移，applied=原锚点；
/// locator 非法/越界 → degradedToPercent（percent × 总字符 → 所在 spine 开头，
/// applied locator 为空对象、percent 保持）；无进度 → noProgress。
///
/// 已知边界（登记 docs/07-R2）：复杂表格/浮动布局降级为顺序文本；
/// 复杂排版整书以流式布局近似，不做 CSS 分页。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:epub_pro/epub_pro.dart' as epub;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        BoxHitTestResult,
        ClipRectLayer,
        PaintingContext,
        PipelineOwner,
        RenderProxyBox,
        ScrollCacheExtent;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../../../../core/design_tokens.dart' show AppLayout;
import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_controller.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import '../../reader_chrome.dart';
import '../../reader_page_turn.dart';
import '../../reader_scroll_physics.dart';
import 'epub_block_parser.dart';
import 'epub_images.dart';
import 'epub_line_meter.dart';
import 'epub_locator.dart';
import 'epub_page_structure.dart';
import 'epub_theme.dart';

/// 进度上报节流窗口（docs/03 §3.1：翻页/滚动 3s 防抖）。
const Duration epubProgressThrottle = Duration(seconds: 3);

/// epub 正文段落首行缩进（A10：2em 全角空格，等价 textIndent——fwfh 无
/// text-indent 样式支持；单一事实源见 reader_settings.dart，只插入显示层，
/// 不改 plainText/locator 坐标）。
const String epubParagraphIndent = kReaderParagraphIndent;

/// 正文滚动视图的**偏移存储槽**（[PageStorageKey]）。
///
/// 框架只在滚动视图挂了 [PageStorageKey] 时才保存/恢复滚动偏移
/// （见 `ScrollPosition.restoreScrollOffset`）：翻页方式切换会重建正文视图
/// （分页视图的包装结构与滚动视图不同），没有这个 key 的话新视图从 0 起
/// ——画面先闪回第一页/封面，之后渲染器再按逻辑位置把位置找回来（中间那
/// 几帧正文还没建出来 = 加载不全，翻一次页才恢复）。
///
/// key 固定 → 重建前后是同一个存储槽 → 偏移被原样接回。
const Key _epubBodyStorageKey = PageStorageKey<String>('epub-body');

/// spine 条目（解析产物：href + 该文件的块序列）。
class _SpineItem {
  const _SpineItem({required this.href, required this.blocks});

  /// 内容文件 href（manifest 原样形态，OPF 相对路径）。
  final String href;

  /// 块序列（可为空：文件缺失/纯图片无 alt 等）。
  final List<EpubBlock> blocks;
}

/// 某块的行盒缓存（块尺寸 + 块内行盒 + 排版代次 + 样式指纹）：块布局未变则复用。
///
/// **失效条件不能只看尺寸**：内容/样式变了但尺寸恰好没变时（例如页边距变了
/// 但段落只有一行、字号与行高互换后总高相同），只比尺寸会命中过期行盒 →
/// 页界按旧行盒位置算 → 把字切了。故同时比对排版代次（epoch）与样式指纹。
class _EpubBlockLines {
  const _EpubBlockLines(
    this.size,
    this.lines, {
    required this.epoch,
    required this.styleKey,
  });

  /// 测量时的块尺寸（尺寸变了即重测）。
  final Size size;

  /// 块内行盒（块局部坐标）。
  final List<EpubLineBox> lines;

  /// 测量时的排版代次（几何变化自增）。
  final int epoch;

  /// 测量时的样式指纹（字号/行高/字体/页边距）。
  final int styleKey;

  /// 缓存是否仍对得上当前的块尺寸与排版参数。
  bool matches(Size current, int currentEpoch, int currentStyleKey) =>
      current.height == size.height &&
      current.width == size.width &&
      epoch == currentEpoch &&
      styleKey == currentStyleKey;
}

/// 页停候选测量结果（一次测量的产物）。
///
/// - [stops]：页停候选（行落点 + 插图原子区间）；
/// - [safeBounds]：安全边界（升序）——可安全裁剪的位置（行落点 / 插图
///   块顶底 / 无行盒块的块底）；
/// - [contentEnd]：已测内容的下边界（文档末尾收尾用）；
/// - [chapterStarts]：章节起点（升序）——新章节另起一页的边界。
class _EpubPageMetrics {
  const _EpubPageMetrics({
    required this.stops,
    required this.safeBounds,
    required this.contentEnd,
    required this.chapterStarts,
  });

  final List<EpubStop> stops;
  final List<double> safeBounds;
  final double? contentEnd;
  final List<double> chapterStarts;
}

/// epub 渲染会话。
class EpubRenderer extends BookRenderer
    implements ReaderPercentJump, ReaderTextProbe {
  EpubRenderer._({
    required this.file,
    required ReaderSettings initialSettings,
    required List<_SpineItem> spines,
  }) : _settings = initialSettings {
    // ---- 拉平：spine → 全书块序列 + 前缀和（percent 与降级恢复的坐标系）----
    var running = 0;
    for (var s = 0; s < spines.length; s++) {
      _spineHrefs.add(spines[s].href);
      _spineStartFlat.add(_blocks.length);
      _spineBlockCounts.add(spines[s].blocks.length);
      for (var b = 0; b < spines[s].blocks.length; b++) {
        _blocks.add(spines[s].blocks[b]);
        _blockSpine.add(s);
        _blockInSpine.add(b);
        _prefixChars.add(running);
        running += spines[s].blocks[b].plainText.length;
      }
    }
    _totalChars = running;
    _keys = List<GlobalKey>.generate(_blocks.length, (_) => GlobalKey());
    controller = EpubReaderController._(this);
    _scrollController.addListener(_handleScroll);
  }

  /// 打开渲染会话：整书解析（epub_pro + XHTML 块化）。初始位置由
  /// [EpubReaderController.restore] 决定（默认从首块开始）。
  static Future<EpubRenderer> open({
    required BookFile file,
    required ReaderSettings settings,
  }) async {
    final bytes = await file.file.readAsBytes();
    final book = await epub.EpubReader.readBook(bytes);
    return EpubRenderer._(
      file: file,
      initialSettings: settings,
      spines: _extractSpines(book),
    );
  }

  /// spine 提取：按 OPF spine 序，逐文件块化解析，图片 src 归一化为 data URI。
  static List<_SpineItem> _extractSpines(epub.EpubBook book) {
    final htmlFiles =
        book.content?.html ?? const <String, epub.EpubTextContentFile>{};
    final images = <String, Uint8List>{
      for (final entry
          in (book.content?.images ??
                  const <String, epub.EpubByteContentFile>{})
              .entries)
        if (entry.value.content != null)
          entry.key: Uint8List.fromList(entry.value.content!),
    };
    final imageMimes = <String, String>{
      for (final entry
          in (book.content?.images ??
                  const <String, epub.EpubByteContentFile>{})
              .entries)
        if (entry.value.contentMimeType != null)
          entry.key: entry.value.contentMimeType!,
    };
    final manifestById = {
      for (final item
          in (book.schema?.package?.manifest?.items ??
              const <epub.EpubManifestItem>[]))
        if (item.id != null) item.id!: item,
    };
    const parser = EpubBlockParser();
    final items = <_SpineItem>[];
    for (final ref
        in book.schema?.package?.spine?.items ??
            const <epub.EpubSpineItemRef>[]) {
      final href = manifestById[ref.idRef]?.href;
      if (href == null) continue; // manifest 缺失项：跳过（导入期已容忍）
      final source = htmlFiles[href]?.content ?? '';
      final blocks = source.isEmpty
          ? const <EpubBlock>[]
          : parser.parse(
              source,
              resolveImage: (src) => resolveEpubImageDataUri(
                src: src,
                chapterHref: href,
                images: images,
                imageMimes: imageMimes,
              ),
            );
      items.add(_SpineItem(href: href, blocks: blocks));
    }
    return items;
  }

  /// 正文文件（诊断用；渲染器持有解析结果，不再重读文件）。
  final BookFile file;

  ReaderSettings _settings;
  bool _disposed = false;

  /// 阅读控制器（宿主唯一交互面）。
  @override
  late final EpubReaderController controller;

  // —— 解析产物（首开缓存；只读）——
  final List<String> _spineHrefs = [];
  final List<int> _spineBlockCounts = [];
  final List<int> _spineStartFlat = [];
  final List<EpubBlock> _blocks = [];
  final List<int> _blockSpine = [];
  final List<int> _blockInSpine = [];
  final List<int> _prefixChars = [];
  late final List<GlobalKey> _keys;
  int _totalChars = 0;

  // —— 逻辑位置与视图 ——
  int _flatIndex = 0;
  int _charOffset = 0;
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  int _layoutEpoch = 0;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();

  /// 已构建块的窗口（ListView 惰性构建；视口测量只扫此窗口）。
  int _builtMin = 1 << 30;
  int _builtMax = -1;

  /// 图片字节解码缓存（块下标 → data URI 解码结果；漫画整页书避免
  /// 每次构建重复 base64 解码）。
  final Map<int, Uint8List?> _imageDecodeCache = {};

  /// 解码图片块的字节（无 data URI 或解码失败返回 null → 走错误占位）。
  Uint8List? decodeImageBytes(int index, String html) {
    if (_imageDecodeCache.containsKey(index)) return _imageDecodeCache[index];
    Uint8List? bytes;
    final m = RegExp(r'''src=["']data:image/[^;]+;base64,([^"']+)["']''')
        .firstMatch(html);
    if (m != null) {
      try {
        bytes = base64Decode(m.group(1)!);
      } on FormatException {
        bytes = null;
      }
    }
    _imageDecodeCache[index] = bytes;
    return bytes;
  }

  // —— 定位收敛（restore/jumpTo/视图重建共用）——
  bool _locating = false;
  int _locateGeneration = 0;
  int _settledIndex = -1;
  bool _recheckScheduled = false;

  /// 翻页委托（v1.4.4，docs/10 §9.21）：page 模式由**视图层**播放统一的
  /// 左右推移动画（双窗口横向交接），渲染器只负责算落点与提交。
  ///
  /// 参数 delta = +1 下一页 / -1 上一页；未挂视图（headless）或非 page
  /// 模式时为 null → 渲染器退回自己的瞬时跳转路径。
  Future<bool> Function(int delta)? _turnDelegate;

  /// 翻页进度（0 = 当前页在位；1 = 下一页完全推入；-1 = 上一页完全推入）。
  ///
  /// 视图层每帧回报（跟手拖拽与补完动画都经它）——测试据此断言「位移 1:1
  /// 跟手」「过阈值补完、不过阈值回弹」。
  double _turnProgress = 0;

  /// 当前翻页进度（只读；测试/诊断用）。
  double get turnProgress => _turnProgress;

  /// 视图层回报翻页进度。
  void reportTurnProgress(double progress) {
    if (_disposed) return;
    _turnProgress = progress;
  }

  // —— 节流上报（照抄 txt 的节流结构）——
  Timer? _pendingReport;
  DateTime _lastReportAt = DateTime.fromMillisecondsSinceEpoch(0);

  // —— 只读状态（集成/测试用）——

  /// 当前生效设置。
  ReaderSettings get settings => _settings;

  /// 当前主题配色。
  EpubThemeColors get themeColors => EpubThemeColors.of(_settings.theme);

  /// 视图重定位总线（applySettings/主题切换触发视图重建）。
  ValueListenable<int> get revision => _revision;

  /// 全书滚动控制器（视图挂载；诊断/测试用）。
  ScrollController get scrollController => _scrollController;

  /// 视口锚点 Key（诊断/测试用）。
  GlobalKey get viewportKey => _viewportKey;

  /// 某块的渲染上下文（诊断/测试用；块未构建返回 null）。
  ///
  /// 页停断言用：把已构建块的渲染树交出去测行盒（行盒不对外暴露）。
  BuildContext? blockContextOf(int index) {
    if (index < 0 || index >= _keys.length) return null;
    return _keys[index].currentContext;
  }

  /// 全书块数。
  int get blockCount => _blocks.length;

  /// spine 数。
  int get spineCount => _spineHrefs.length;

  /// 当前逻辑位置：spine 序号。
  int get positionSpine => _blocks.isEmpty
      ? 0
      : _blockSpine[_flatIndex.clamp(0, _blocks.length - 1)];

  /// 当前逻辑位置：spine 内块序号。
  int get positionBlockInSpine => _blocks.isEmpty
      ? 0
      : _blockInSpine[_flatIndex.clamp(0, _blocks.length - 1)];

  /// 当前逻辑位置：块内字符偏移。
  int get positionOffset => _charOffset.clamp(0, _blockLength(_flatIndex));

  /// 全书总字符数（percent 分母；测试用）。
  int get totalChars => _totalChars;

  /// 某块纯文本（下标钳制；测试用）。
  String blockPlainText(int index) =>
      _blocks[index.clamp(0, _blocks.length - 1)].plainText;

  /// 某块 html 片段（下标钳制；测试用，断言图片 data URI 替换）。
  String blockHtml(int index) =>
      _blocks[index.clamp(0, _blocks.length - 1)].html;

  /// 页停候选（诊断/测试用）：已累积的候选表（升序）。
  ///
  /// 断言用：插图必须登记为「块顶 + 块底」的原子区间（页界不得入其内）。
  List<EpubStop> get pageStops => List<EpubStop>.unmodifiable(_pages.stops);

  /// 页起点链（诊断/测试用）：走过的页起点（升序）。
  List<double> get pageStarts => List<double>.unmodifiable(_pages.chain);

  /// 章节起点（诊断/测试用）：已测得的章边界（升序，文档坐标）。
  ///
  /// 章边界 = spine 首块顶：**新章节另起一页**——页终点不得越过它。
  List<double> get chapterStarts =>
      List<double>.unmodifiable(_pages.chapterStarts);

  /// 正文基础样式（字号/行距/字体/前景色随设置即时生效；衬线为默认，Q2）。
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

  // —— 位置与进度 ——

  int _blockLength(int flat) {
    if (_blocks.isEmpty) return 0;
    return _blocks[flat.clamp(0, _blocks.length - 1)].plainText.length;
  }

  /// 当前全书进度 =（当前块之前累计字符 + 块内偏移）/ 全书总字符 ∈ [0,1]。
  double get percent {
    if (_blocks.isEmpty || _totalChars <= 0) return 0;
    final i = _flatIndex.clamp(0, _blocks.length - 1);
    final off = _charOffset.clamp(0, _blocks[i].plainText.length);
    return ((_prefixChars[i] + off) / _totalChars).clamp(0.0, 1.0);
  }

  /// 当前逻辑位置快照（宿主退出/切后台时兜底落库用，FR-207）。
  ProgressAnchor get currentLocator {
    if (_blocks.isEmpty || _spineHrefs.isEmpty) {
      return ProgressAnchor(
        locatorJson: EpubLocatorCodec.encode(
          spineIndex: 0,
          href: '',
          blockIndex: 0,
          charOffset: 0,
        ),
        percent: 0,
        hasProgress: true,
      );
    }
    final i = _flatIndex.clamp(0, _blocks.length - 1);
    final spine = _blockSpine[i];
    return ProgressAnchor(
      locatorJson: EpubLocatorCodec.encode(
        spineIndex: spine,
        href: _spineHrefs[spine],
        blockIndex: _blockInSpine[i],
        charOffset: _charOffset.clamp(0, _blocks[i].plainText.length),
      ),
      percent: percent,
      hasProgress: true,
    );
  }

  void _setPosition(int flat, int charOffset) {
    if (_blocks.isEmpty) {
      _flatIndex = 0;
      _charOffset = 0;
      return;
    }
    _flatIndex = flat.clamp(0, _blocks.length - 1);
    _charOffset = charOffset.clamp(0, _blocks[_flatIndex].plainText.length);
  }

  /// 视图/定位流程产生的位置变化，节流后上报宿主。
  void _scheduleProgressReport() {
    if (_disposed || controller.onProgressChanged == null) return;
    if (_pendingReport != null) return; // 已有待发上报（合并高频滚动）
    final elapsed = DateTime.now().difference(_lastReportAt);
    if (elapsed >= epubProgressThrottle) {
      _fireProgressReport();
      return;
    }
    _pendingReport = Timer(epubProgressThrottle - elapsed, () {
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
  /// 1. 无进度（或空书）→ noProgress，从首块开始；
  /// 2. locator 非法（type 不符/字段缺失/损坏 JSON）、spineIndex 越界、
  ///    href 归一化不匹配或 blockIndex 越界 → degradedToPercent：
  ///    percent × 总字符 → 定位到所在 spine 的开头（最近章节开头），
  ///    applied 的 locator 为空对象、percent 保持不变（契约约定）；
  /// 3. 合法 locator → exact：滚到块顶，块内按 charOffset/plainText 长度
  ///    比例估偏移；applied = 原锚点。
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async {
    if (_disposed) {
      return const ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    }
    if (!saved.hasProgress || _blocks.isEmpty) {
      _setPosition(0, 0);
      return const ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    }
    final data = EpubLocatorCodec.tryDecode(saved.locatorJson);
    if (data != null && _isExactRestore(data)) {
      final flat = _spineStartFlat[data.spineIndex] + data.blockIndex;
      _setPosition(flat, data.charOffset);
      _breakPageChain(); // 位置语义断裂：旧页起点链作废
      await _locatePosition();
      _registerLanding();
      return ReaderRestoreResult(
        mode: ReaderRestoreMode.exact,
        applied: saved, // applied=原锚点（契约约定）
      );
    }
    // 降级：percent × 总字符 → 所在 spine 的开头。
    final target = (saved.percent.clamp(0.0, 1.0) * _totalChars).round();
    final flat = EpubPositionMath.flatIndexAtCharOffset(_prefixChars, target);
    final spine = _blockSpine[flat.clamp(0, _blocks.length - 1)];
    final start = _spineStartFlat[spine];
    _setPosition(start < 0 ? 0 : start, 0);
    _breakPageChain(); // 位置语义断裂：旧页起点链作废
    await _locatePosition();
    _registerLanding();
    return ReaderRestoreResult(
      mode: ReaderRestoreMode.degradedToPercent,
      applied: ProgressAnchor(
        locatorJson: '{}',
        percent: saved.percent,
        hasProgress: true,
      ),
    );
  }

  /// exact 恢复合法性：spineIndex 界内 + href 归一化匹配 + blockIndex 界内。
  bool _isExactRestore(EpubLocatorData data) {
    if (data.spineIndex < 0 || data.spineIndex >= _spineHrefs.length) {
      return false;
    }
    if (EpubPositionMath.normalizeHref(data.href) !=
        EpubPositionMath.normalizeHref(_spineHrefs[data.spineIndex])) {
      return false;
    }
    return data.blockIndex >= 0 &&
        data.blockIndex < _spineBlockCounts[data.spineIndex];
  }

  /// 跳转到目录条目：anchor 为 [EpubSpineAnchor]（可能带 fragment）→
  /// 滚到该 spine 首块（空 spine 顺延到最近有块的 spine）。
  Future<void> jumpToTocEntry(TocEntry entry) async {
    if (_disposed || _blocks.isEmpty || _spineHrefs.isEmpty) return;
    final anchor = entry.anchor;
    final parsed = anchor is EpubSpineAnchor
        ? anchor
        : EpubSpineAnchor.tryParse(anchor.toString());
    if (parsed == null) return;
    final s = parsed.spineIndex.clamp(0, _spineHrefs.length - 1);
    var flat = _spineStartFlat[s];
    if (flat < 0) {
      for (var k = s + 1; k < _spineStartFlat.length && flat < 0; k++) {
        flat = _spineStartFlat[k];
      }
      for (var k = s - 1; k >= 0 && flat < 0; k--) {
        flat = _spineStartFlat[k];
      }
    }
    if (flat < 0) return;
    _setPosition(flat, 0);
    // 跳转 = 位置语义断裂：旧页起点与新位置不再相邻 → 旧链作废
    // （否则弹道吸附把页面吸回旧位置、翻页沿旧链跳回旧章，见
    //  [EpubPageStructure.invalidateChain]）。
    _breakPageChain();
    await _locatePosition();
    _registerLanding();
    _scheduleProgressReport();
  }

  /// 跳转/恢复 = 位置语义断裂：页起点链整体作废。
  ///
  /// 旧位置的页起点与新位置**不再相邻**（中间隔着未走过的整段内容），
  /// 留着旧链会让弹道吸附把页面吸回旧位置（跳转后弹回、来回翻页），
  /// 翻页也会沿旧链跳回旧章。
  void _breakPageChain() {
    _pages.invalidateChain();
  }

  /// 把当前落点登记为新页起点（跳转后翻页往返以它为锚）。
  void _registerLanding() {
    if (_disposed || !_scrollController.hasClients) return;
    _pages.registerPageStart(_scrollController.offset);
  }

  // —— 翻页（音量键翻页 FR-209，契约 nextPage/previousPage）——

  /// 翻到下一页：page 模式落到**下一个页起点**（页界不切字、插图独占一页，
  /// 见 [EpubPageStructure]）；scroll 模式滚一屏。视图未挂载或已在文档末尾
  /// 返回 false。
  Future<bool> nextPage() => _turnPage(1);

  /// 翻到上一页：语义同 [nextPage]，方向相反。
  Future<bool> previousPage() => _turnPage(-1);

  Future<bool> _turnPage(int delta) {
    if (_disposed || _blocks.isEmpty) return Future.value(false);
    final ctrl = _scrollController;
    if (!ctrl.hasClients) return Future.value(false); // 视图未挂载
    final position = ctrl.position;
    final viewport = position.viewportDimension;
    if (_settings.pageMode != ReaderPageMode.page) {
      // scroll 模式：一页/一屏 = 视口高度（连续滚动，不吸附）。
      final target = (ctrl.offset + delta * viewport).clamp(
        0.0,
        position.maxScrollExtent,
      );
      if ((target - ctrl.offset).abs() < 0.5) return Future.value(false);
      ctrl.jumpTo(target); // 触发 _handleScroll → 位置更新 + 节流上报
      return Future.value(true);
    }
    // page 模式：优先交给**视图层**播放统一的左右推移动画（v1.4.4，
    // docs/10 §9.21）——双窗口横向交接，跟手 + 补完/回弹。
    final delegate = _turnDelegate;
    if (delegate != null) return delegate(delta);
    // 视图未挂载（headless）：退回瞬时跳转（落点语义与动画路径一致）。
    return _turnPageInPageMode(delta, viewport);
  }

  // —— 翻页动画支撑（视图层调用；docs/10 §9.21）——

  /// 相邻页起点（只读探测，不写页起点链）。
  ///
  /// 视图层用它准备**推入页窗口**（双窗口交接的另一半）。null = 没有相邻
  /// 页（已在首/末页）或页结构尚未测出。
  double? pageTurnTargetFor(int delta) {
    if (_disposed || !_scrollController.hasClients) return null;
    final ctrl = _scrollController;
    final viewport = ctrl.position.viewportDimension;
    return _pageTurnTarget(ctrl.offset, delta, viewport);
  }

  /// 请求翻页（page 模式）：算落点 → 交给视图层播放左右推移动画。
  ///
  /// 返回是否**发起**了翻页：目标页存在即算发起（不可达时先逼出更多内容，
  /// 下一帧重试——翻页仍会发生）；已在首/末页（没有相邻页）返回 false。
  ///
  /// 可达性是硬要求：惰性列表的 `maxScrollExtent` 只是「已构建内容」的高度，
  /// 直接跳到超出末尾的页起点会被静默 clamp 到末尾（非页起点）→ 页界失效、
  /// 页起点链被污染（用户实测「分页模式下滚轮会乱翻」）。
  ///
  /// 刻意**不 await 帧**：翻页是同步手势（按键/热区），等帧会把调用方卡住
  /// （widget 测试会挂住）——重试走 [WidgetsBinding.instance
  /// .addPostFrameCallback]。
  bool requestTurn(int delta, void Function(double target) onReady) {
    if (_disposed || !_scrollController.hasClients) return false;
    return _requestTurn(delta, onReady, 0);
  }

  /// 请求翻页的递归实现（[requestTurn]）。
  bool _requestTurn(int delta, void Function(double) onReady, int attempt) {
    final ctrl = _scrollController;
    if (_disposed || !ctrl.hasClients) return false;
    final viewport = ctrl.position.viewportDimension;
    final origin = ctrl.offset;
    final target = _pageTurnTarget(origin, delta, viewport);
    if (target == null) return false; // 没有相邻页（首/末页）
    final max = ctrl.position.maxScrollExtent;
    if (target > max + 0.5) {
      // 目标超出末尾：滚到末尾逼出更多内容（惰性构建 → 末尾变长），下一帧再翻。
      if (attempt >= _pageTurnGrowAttempts) return false;
      if ((max - ctrl.offset).abs() < 0.5) return false; // 已在末尾
      ctrl.jumpTo(max);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        _requestTurn(delta, onReady, attempt + 1);
      });
      return true; // 已发起（下一帧兑现）
    }
    final clamped = target.clamp(0.0, max);
    // 无实际移动（已在首/末页）：相邻页起点与当前位置重合 → 不翻。
    if ((clamped - origin).abs() < 0.5) return false;
    onReady(clamped);
    return true;
  }

  /// 提交翻页落点：登记进页起点链**再**跳转。
  ///
  /// 顺序不能反：jumpTo 末尾会触发一次 `goBallistic(0)`，弹道按「就近页
  /// 起点」吸附；链里若没有刚落点这一页，弹道会把页面**拽回上一页**
  /// （实测：翻页后位置倒退一整页，翻页在两页间来回跳 = 用户说的「乱翻」）。
  void commitPageStart(double target) {
    if (_disposed || !_scrollController.hasClients) return;
    _pages.registerPageStart(target);
    _scrollController.jumpTo(target);
  }

  /// 指定起点处的**一页内容高度**（页终点 - 起点；≤ 一屏）。
  ///
  /// 与 [pageContentHeight] **同一口径、同一保守兜底**（页终点 = 下一个页
  /// 起点 = 行边界/插图边界，页尾不足一行处留白）：
  ///
  /// ① 页终点候选已知 → 用它；
  /// ② 候选未知 → 裁到视口内最后一条**安全边界**（宁可页尾多留白）；
  /// ③ 内容到此为止（文档末尾）→ 整段露出；
  /// ④ 什么都没有 → **留白**。
  ///
  /// **绝不退化成整屏**：整屏的切线落在任意 y 上，会把一行字拦腰切断——
  /// 推入页（旧实现按固定高度开窗，候选未知时直接给满一屏）因此会在翻页
  /// 途中露出半行，收尾后又消失（用户实测「翻页时一闪一截断的行」）。
  double pageContentHeightAt(double start, double viewportHeight) {
    if (_disposed || !_scrollController.hasClients) return 0;
    // 面板重建期可能短暂挂了两个滚动视图（同一 controller）→ 不取位置。
    if (_scrollController.positions.length != 1) return 0;
    // 口径与兜底全在 [EpubPageStructure.contentHeightAt]（纯 Dart，可单测）。
    return _pages.contentHeightAt(start, viewportHeight);
  }

  /// 目标页窗口的块区间（翻页动画的**推入页**复制渲染用）。
  ///
  /// 返回 (首块下标, 末块下标, 首块文档坐标顶)。目标页是**连续排版上的
  /// 一个偏移区间**，不是独立内容——要让它与当前页同时可见，只能复制一份
  /// 块渲染（复制件用独立 key，测量仍只认主列表的 GlobalKey）。
  ///
  /// null = 目标页的块尚未构建（惰性窗口外）→ 本次不做推入页窗口。
  (int, int, double)? pageWindowBlocks(double start, double end) {
    if (_disposed || !_scrollController.hasClients) return null;
    final viewportBox = _renderBoxOf(_viewportKey.currentContext);
    if (viewportBox == null || !viewportBox.hasSize) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final base = _scrollController.positions.length == 1
        ? _scrollController.offset
        : 0.0;
    int? first;
    int? last;
    double? firstTop;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _renderBoxOf(_keys[i].currentContext);
      if (box == null || !box.attached || !box.hasSize) continue;
      final top = base + box.localToGlobal(Offset.zero).dy - viewportTop;
      final bottom = top + box.size.height;
      if (bottom <= start) continue; // 整块在目标页之前
      if (top >= end) break; // 整块在目标页之后（块序号递增）
      first ??= i;
      last = i;
      firstTop ??= top;
    }
    if (first == null || last == null || firstTop == null) return null;
    return (first, last, firstTop);
  }

  /// page 模式的翻页：目标 = 相邻**页起点**，且目标必须**可达**。
  ///
  /// 可达性是硬要求：惰性列表的 `maxScrollExtent` 只是「**已构建内容**」的
  /// 高度（未测到的区域还没算进去，且块被回收后会回落——见 v1.3.5 滚动条
  /// 跳变的同一根源）。直接 `jumpTo` 一个超出末尾的页起点会被**静默 clamp**
  /// 到末尾（一个**非页起点**的位置）→ 页界失效、页起点链被污染 → 后续
  /// 翻页越翻越乱（用户实测「分页模式下用滚轮会出现乱翻」）。
  ///
  /// 故：目标超出末尾时，先滚到末尾**逼出更多内容**（末尾随之变长），**下
  /// 一帧**再翻（最多 [_pageTurnGrowAttempts] 次）；仍不可达则不翻
  /// （宁可这一格不动，也不要落到页中间把页界搞坏）。
  ///
  /// 刻意**不 await 帧**：翻页是同步手势（滚轮/按键），等一帧会把调用方
  /// 卡住（widget 测试会挂住）。
  Future<bool> _turnPageInPageMode(int delta, double viewport) {
    return _turnPageFrom(delta, viewport, _scrollController.offset, 0);
  }

  /// 从 [origin] 翻页（[attempt] = 已尝试「逼出更多内容」的次数）。
  Future<bool> _turnPageFrom(
    int delta,
    double viewport,
    double origin,
    int attempt,
  ) async {
    final ctrl = _scrollController;
    if (_disposed || !ctrl.hasClients) return false;
    final target = _pageTurnTarget(origin, delta, viewport);
    if (target == null) return false;
    final max = ctrl.position.maxScrollExtent;
    if (target > max + 0.5) {
      // 目标超出末尾：滚到末尾逼出更多内容（惰性构建 → 末尾变长），下一帧再翻。
      if (attempt >= _pageTurnGrowAttempts) return false;
      if ((max - ctrl.offset).abs() < 0.5) return false;
      ctrl.jumpTo(max);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        unawaited(_turnPageFrom(delta, viewport, origin, attempt + 1));
      });
      return false;
    }
    final clamped = target.clamp(0.0, max);
    if ((clamped - ctrl.offset).abs() < 0.5) return false;
    // 落点即页起点 → **先**登记进页起点链，再跳：
    // jumpTo 末尾会触发一次 goBallistic(0)，弹道按「就近页起点」吸附；
    // 链里若没有刚落点这一页，弹道会把页面**拽回上一页**（实测：翻页后位置
    // 倒退一整页，翻页在两页间来回跳 = 用户说的「乱翻」）。
    // 用只读探测算目标（peek*）而非 nextPageStart：后者会把**够不到的**
    // 页起点也写进链，链被污染后翻页会一直瞄着不可达的目标。
    _pages.registerPageStart(clamped);
    ctrl.jumpTo(clamped); // 触发 _handleScroll → 位置更新 + 节流上报
    return true;
  }

  /// 翻页目标：相对 [origin] 的相邻页起点（只读探测，不写页起点链）。
  ///
  /// 页结构候选未知时退回「一屏」盲跳（仍受可达性检查约束）。
  double? _pageTurnTarget(double origin, int delta, double viewport) {
    final ctrl = _scrollController;
    if (!ctrl.hasClients) return null;
    // 先用现测候选刷新页结构（翻页必须基于最新行盒——布局刚变时缓存是旧的）。
    _pages.viewport = viewport;
    final metrics = _measureMetrics(_renderBoxOf(_viewportKey.currentContext));
    _pages.setStops(
      metrics.stops,
      epoch: _layoutEpoch,
      safeBounds: metrics.safeBounds,
      contentEnd: metrics.contentEnd,
      chapterStarts: metrics.chapterStarts,
    );
    final stop = delta > 0
        ? _pages.peekNextPageStart(origin)
        : _pages.peekPrevPageStart(origin);
    return stop ?? (origin + delta * viewport);
  }

  /// 翻页时「逼出更多内容」的最大尝试次数（末尾变长后目标才可达）。
  static const int _pageTurnGrowAttempts = 4;

  // —— page 模式：页结构（页界不切字 + 插图独占一页）——
  //
  // 旧实现：page 模式用 `PageScrollPhysics`，吸附单位 = 视口高，页界落在
  // 视口高的整数倍上——而正文是连续排版的行，行与页界毫无关系，于是页界
  // 把行拦腰切断（章题只显示上半截、页尾只显示半行）。
  //
  // 现在：把「页界」定义成**页起点**（[EpubPageStructure]）：
  // - 候选 = 已构建块测得的行安全落点（正文）+ 图片块的块顶/块底（原子）；
  // - 文本页的终点 = 一屏之内最靠下的候选（页尾留白不足一行）；
  // - **插图独占一页**：一屏之内出现图片 → 该页终点 = 图片块顶（插图另起
  //   一页）；本页从图片块顶起 → 终点 = 图片块底（页界绝不入图片内部，
  //   插图不会被切成两页各露一半）；
  // - 走过的页起点记入页起点链 → 前后翻页**精确往返**（下一页→上一页回到
  //   原落点），不再出现「按一次键翻两页 / 退不回去」。
  //
  // 文档坐标 = 视口顶在整书内容中的 y（滚动偏移即该坐标），故「滚动偏移 =
  // 某行安全落点」⇒ 页界正落在行与行之间。
  //
  // 测量时机：渲染树度量（读 size / localToGlobal）**只能在布局阶段之外**
  // 做（布局中读子节点 size 会被框架断言：只有父节点有此权限）。故：
  // - 帧末（post-frame）刷新页停候选 → 弹道物理（布局阶段创建仿真）读缓存；
  // - 视口裁剪（绘制阶段）与翻页动作（事件回调）现测。

  /// 行盒缓存：块下标 → (块尺寸, 块内行盒, 排版代次, 样式指纹)。块布局未变
  /// 则复用（引擎取行盒较贵，翻页/滚动时每帧都会用到）。
  final Map<int, _EpubBlockLines> _lineCache = {};

  /// 页结构：页停候选（当前测量）+ 安全边界 + 页起点链（走过的页起点）。
  ///
  /// 候选表**整表替换**（不跨滚动累积）：块的排版会随上方内容落定而微移，
  /// 累积旧坐标会让同一张插图在表里出现两个块顶（页界就会算错）；整表替换
  /// 保证「同一时刻测得的一组坐标」自洽——前后翻页的精确往返由页起点链
  /// （[EpubPageStructure.chain]）负责。几何变化时整体作废（见
  /// [_invalidateLineCache]）。
  final EpubPageStructure _pages = EpubPageStructure(viewport: 600);

  /// 页停缓存刷新是否已排队。
  bool _stopRefreshScheduled = false;

  /// 安排帧末刷新页停候选（此时布局已定稿，可安全测量渲染树）。
  ///
  /// 帧末测量是「页界落点」的唯一来源：行盒/块位置在布局定稿后才可读。
  /// 裁剪用这份数据，但裁剪矩形在**绘制阶段**现算（框架的 CustomClipper 会
  /// 缓存裁剪矩形，旧实现因此永远停在首帧的值 → 页尾的半行/半图一直露着）。
  /// 数据晚一帧，但 page 模式多预建一屏（下一行的落点已提前量到）→ 页界仍
  /// 落在行与行之间，且不会「先露半行再收紧」。
  void scheduleStopRefresh() {
    if (_stopRefreshScheduled || _disposed) return;
    _stopRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopRefreshScheduled = false;
      if (_disposed) return;
      final metrics = _measureMetrics(
        _renderBoxOf(_viewportKey.currentContext),
      );
      _pages.viewport = _lastViewportHeight;
      _pages.setStops(
        metrics.stops,
        epoch: _layoutEpoch,
        safeBounds: metrics.safeBounds,
        contentEnd: metrics.contentEnd,
        chapterStarts: metrics.chapterStarts,
      );
    });
  }

  /// 最近一次的视口高（帧末测量时页结构需要它）。
  double _lastViewportHeight = 600;

  /// 样式指纹：字号/行高/字体/页边距——任一变化都可能改变行盒位置
  /// （页边距变 → 列宽变 → 折行点变；字号/行高变 → 行盒高度变）。
  ///
  /// 行盒缓存只比尺寸是不够的：内容变了但尺寸恰好没变时会命中过期行盒。
  int get _styleKey => Object.hash(
    _settings.fontSize,
    _settings.lineHeight,
    _settings.fontFamily,
    _settings.pageMargin,
  );

  /// 行盒缓存失效（排版几何变化时）：行盒位置全变，重测。
  ///
  /// 页停候选与页起点链一并作废（几何变了，旧落点全部失效）。
  void _invalidateLineCache() {
    _lineCache.clear();
    _pages.clear();
  }

  /// 某块的行盒（块局部坐标）：块尺寸与排版参数未变则复用缓存。
  List<EpubLineBox> _blockLineBoxes(int index, RenderBox box) {
    final epoch = _layoutEpoch;
    final styleKey = _styleKey;
    final cached = _lineCache[index];
    if (cached != null && cached.matches(box.size, epoch, styleKey)) {
      return cached.lines;
    }
    final lines = measureEpubLineBoxes(box, baseFontSize: _settings.fontSize);
    _lineCache[index] = _EpubBlockLines(
      box.size,
      lines,
      epoch: epoch,
      styleKey: styleKey,
    );
    return lines;
  }

  /// 取渲染对象（元素失活时返回 null）。
  ///
  /// 重建期测量会碰到**已失活**的元素（`findRenderObject` 会抛
  /// "Cannot get renderObject of inactive element"），故这里兜住异常：
  /// 失活的元素本次不参与测量（下一帧即恢复）。
  static RenderBox? _renderBoxOf(BuildContext? context) {
    if (context == null) return null;
    RenderObject? object;
    try {
      object = context.findRenderObject();
    } on Object {
      return null;
    }
    return object is RenderBox ? object : null;
  }

  /// page 模式视口的渲染对象（裁剪由它在绘制阶段施加）。
  ///
  /// 滚动时列表视图**自身**重绘（内部 repaint boundary），本对象不一定被
  /// 标脏 → 裁剪会停在旧值（页尾的半行又露出来）。故滚动时显式请它重绘。
  _RenderEpubPageViewport? _viewportRenderObject;

  /// 页停候选 + 安全边界 + 内容下边界 + 章节起点——**现测**（须在布局阶段之外
  /// 调用：渲染树度量（读 size / localToGlobal）在布局阶段会触发框架断言）。
  ///
  /// [viewportBox]：视口渲染盒（列表视图本身）。
  _EpubPageMetrics _measureMetrics(RenderBox? viewportBox) {
    if (viewportBox == null || !viewportBox.hasSize) {
      return const _EpubPageMetrics(
        stops: [],
        safeBounds: [],
        contentEnd: null,
        chapterStarts: [],
      );
    }
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final base =
        _scrollController.hasClients && _scrollController.positions.length == 1
        ? _scrollController.offset
        : 0.0;
    final stops = <EpubStop>[];
    final safe = <double>[];
    final chapterStarts = <double>[];
    double? contentEnd;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _renderBoxOf(_keys[i].currentContext);
      if (box == null || !box.attached || !box.hasSize) continue;
      final blockTop = base + box.localToGlobal(Offset.zero).dy - viewportTop;
      final blockBottom = blockTop + box.size.height;
      if (contentEnd == null || blockBottom > contentEnd) {
        contentEnd = blockBottom;
      }
      if (_isSpineStart(i)) {
        // 章节起点（spine 首块顶）：**新章节另起一页**——页终点不得越过它，
        // 它本身即合法页起点（章题不被挤在上一页尾部）。
        chapterStarts.add(blockTop);
        safe.add(blockTop);
      }
      if (_isImageBlock(i)) {
        // 图片块 = **原子区间** [块顶, 块底]：页界不得落在其内部 → 插图
        // 独占一页（不会被切成两页各露一半）。块底同时登记为候选，插图页
        // 的下一页就从块底起。
        stops.add(EpubStop.image(blockTop, blockBottom));
        stops.add(EpubStop.text(blockBottom));
        safe
          ..add(blockTop)
          ..add(blockBottom);
        continue;
      }
      final lines = _blockLineBoxes(i, box);
      if (lines.isEmpty) {
        // 无行盒（复杂表格/浮动布局等降级场景，docs/07-R2）：块顶/块底作
        // 安全边界（块底在末行之下，切在块底不会切字）。
        safe
          ..add(blockTop)
          ..add(blockBottom);
        continue;
      }
      for (final line in lines) {
        // 落点取「安全落点」（行盒顶上移余量），不是行盒顶——中日韩字面
        // 常高于字体 ascent 带，按行盒顶落点仍会削掉字形顶部。
        final landing = blockTop + line.landing;
        stops.add(EpubStop.text(landing));
        safe.add(landing);
      }
      safe.add(blockBottom);
    }
    stops.sort((a, b) => a.pos.compareTo(b.pos));
    safe.sort();
    chapterStarts.sort();
    return _EpubPageMetrics(
      stops: stops,
      safeBounds: safe,
      contentEnd: contentEnd,
      chapterStarts: chapterStarts,
    );
  }

  /// 块是否为某 spine 的**首块**（= 章节起点）。
  ///
  /// epub 的目录条目粒度 = spine（内容文件），故章边界 = spine 边界。
  ///
  /// 首章（spine 0）**不算**边界：它的首块就在文档顶端（前面只有列表的
  /// 顶部内边距），若把它当边界，第一页会变成「只有内边距的空页」。
  bool _isSpineStart(int index) {
    if (index < 0 || index >= _blocks.length) return false;
    final spine = _blockSpine[index];
    if (spine <= 0 || spine >= _spineStartFlat.length) return false;
    return _spineStartFlat[spine] == index;
  }

  /// 记录视口高（绘制阶段调用）：帧末测量按它换算「一屏」的长度。
  void noteViewportHeight(double viewportHeight) {
    if (_disposed) return;
    _lastViewportHeight = viewportHeight;
  }

  /// 块是否为图片块（整页槽；解析层仍是 paragraph/见 [_isImageOnlyBlock]）。
  bool _isImageBlock(int index) {
    final block = _blocks[index];
    if (block.kind == EpubBlockKind.image) return true;
    return block.kind == EpubBlockKind.paragraph && _isImageOnlyBlock(block);
  }

  /// page 模式本页内容高度：当前落点 → 下一个页起点的距离（≤ 一屏）。
  ///
  /// 视口按此高度裁剪：页尾不足一行处留白，页界不落在任何字形中间；插图
  /// 页的高度 = 插图块高（插图独占一页，不与上下文字挤在一起）。
  ///
  /// **绝不因为「候选未知」就退化成整屏不裁剪**——那会让被页界切断的半行/
  /// 半图先露出来、下一帧又消失（用户看到的闪烁）。候选未知时按保守值收：
  /// ① 视口内最后一条安全边界（宁可页尾多留白）；② 内容到此为止（文档
  /// 末尾，整段露出）；③ 什么都没有 → 留白（0），宁可空白也不切字。
  double pageContentHeight(double viewportHeight) {
    if (_disposed || !_scrollController.hasClients) return viewportHeight;
    // 面板重建期可能短暂挂了两个滚动视图（同一 controller）→ 不取位置。
    if (_scrollController.positions.length != 1) return viewportHeight;
    return pageContentHeightAt(_scrollController.offset, viewportHeight);
  }

  /// 按全书比例跳转（[ReaderPercentJump] 契约；进度滑块用）：
  /// percent × 总字符 → 所在块（与降级恢复同一换算），块内偏移清零后定位。
  @override
  Future<void> jumpToPercent(double percent) async {
    if (_disposed || _blocks.isEmpty) return;
    final target = (percent.clamp(0.0, 1.0) * _totalChars).round();
    final flat = EpubPositionMath.flatIndexAtCharOffset(_prefixChars, target);
    _setPosition(flat, 0);
    _breakPageChain(); // 位置语义断裂：旧页起点链作废
    await _locatePosition();
    _registerLanding();
    _scheduleProgressReport();
  }

  /// 目录条目是否为当前 spine（[BookRenderer.isTocEntryCurrent] 契约）。
  @override
  bool isTocEntryCurrent(TocEntry entry) {
    final anchor = entry.anchor;
    final parsed = anchor is EpubSpineAnchor
        ? anchor
        : EpubSpineAnchor.tryParse(anchor.toString());
    if (parsed == null) return false;
    return parsed.spineIndex == positionSpine;
  }

  /// B6 文字命中判定：点击点是否落在任一**已构建块**的盒内（块粒度，
  /// 对齐原型「点空白显隐」的可用精度；fwfh 的块内字形盒不对外暴露）。
  ///
  /// 块盒含块尾距（fontSize×0.35），该段留白判为非文字，块与块之间的
  /// 空隙可正常唤出/收起控制条。视图未挂载（headless）返回 false。
  @override
  bool isTextAt(Offset globalPosition) {
    if (_disposed || _blocks.isEmpty) return false;
    final blockTail = _settings.fontSize * 0.35;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _renderBoxOf(_keys[i].currentContext);
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(globalPosition);
      if (local.dx < -4 ||
          local.dy < -4 ||
          local.dx > box.size.width + 4 ||
          local.dy > box.size.height - blockTail + 4) {
        continue;
      }
      return true;
    }
    return false;
  }

  // —— 设置变更（宿主经 dynamic 调用，FR-206）——

  /// 应用新设置：字号/行距/页边距/字体/主题/翻页模式全部生效。
  /// 排版几何变化 → [EpubRenderer._layoutEpoch] 自增，视图面板整体重建
  /// （新 physics/padding/样式），重建后按"当前块 + 块内字符偏移"锚点复位
  /// 位置；主题色由视图重建直接生效，位置不变。
  void applySettings(ReaderSettings next) {
    if (_disposed || next == _settings) return;
    final old = _settings;
    _settings = next;
    final geometryChanged =
        next.fontSize != old.fontSize ||
        next.lineHeight != old.lineHeight ||
        next.pageMargin != old.pageMargin ||
        next.fontFamily != old.fontFamily ||
        next.pageMode != old.pageMode;
    if (geometryChanged) _layoutEpoch++;
    if (geometryChanged) _invalidateLineCache(); // 行盒全变，重新测量
    _bumpRevision();
  }

  void _bumpRevision() {
    if (!_disposed) _revision.value++;
  }

  // —— 滚动定位（视图消费）——

  /// 滚动定位到渲染器当前逻辑位置（restore/jumpTo/面板重建后调用）。
  ///
  /// 视图未挂载时直接返回（面板 initState 会在首帧后再调）；否则先按
  /// 字符比例估算偏移起步，目标块构建后按实测块顶位移差逐帧收敛（≤12 轮）。
  ///
  Future<void> locateFromView() => _locatePosition();

  Future<void> _locatePosition() async {
    if (_disposed || _blocks.isEmpty) return;
    if (!_scrollController.hasClients) return;
    final gen = ++_locateGeneration;
    _locating = true; // 定位产生的滚动不回写位置（避免覆盖目标）
    try {
      for (var attempt = 0; attempt < 12; attempt++) {
        if (_disposed || gen != _locateGeneration) return;
        final measured = _blockTopDelta(_flatIndex);
        if (measured != null) {
          final (delta, height) = measured;
          final len = _blockLength(_flatIndex);
          final frac = len > 0 ? _charOffset / len : 0.0;
          final targetDelta = delta + frac * height;
          if (targetDelta.abs() <= 1.5) {
            _updateFromViewport(force: true);
            return;
          }
          final position = _scrollController.position;
          final offset = _scrollController.offset;
          final atTop = offset <= 0.5;
          final atBottom = offset >= position.maxScrollExtent - 0.5;
          if ((targetDelta < 0 && atTop) || (targetDelta > 0 && atBottom)) {
            // 已到文档端头且目标仍偏在一侧：视为已到端点，就地收敛。
            _updateFromViewport(force: true);
            return;
          }
          _scrollController.jumpTo(
            (offset + targetDelta).clamp(0.0, position.maxScrollExtent),
          );
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }
        // 目标块未构建（惰性窗口外）：按估算先跳，下一轮可测。
        final max = _scrollController.position.maxScrollExtent;
        if (max > 0 && _totalChars > 0) {
          final i = _flatIndex.clamp(0, _blocks.length - 1);
          final estimate = _estimateOffset(i);
          if (estimate == null) {
            // 内容不足一屏（无滚动空间）：目标块必在视口内，直接收敛。
            // （此处不可 await endOfFrame——无 jumpTo 则无新帧，会永久挂起。）
            _updateFromViewport(force: true);
            return;
          }
          _scrollController.jumpTo(estimate.clamp(0.0, max));
          await WidgetsBinding.instance.endOfFrame;
          continue;
        }
        // 内容不足一屏（无滚动空间）：目标块必在视口内，直接收敛。
        // （此处不可 await endOfFrame——无 jumpTo 则无新帧，会永久挂起。）
        _updateFromViewport(force: true);
        return;
      }
      _updateFromViewport(force: true);
    } finally {
      if (gen == _locateGeneration) _locating = false;
    }
  }

  /// 目标块顶相对视口顶的位移与块高（逻辑像素；块未构建/未布局返回 null）。
  (double, double)? _blockTopDelta(int flat) {
    if (flat < 0 || flat >= _keys.length) return null;
    final box = _renderBoxOf(_keys[flat].currentContext);
    final viewportBox = _renderBoxOf(_viewportKey.currentContext);
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final dy =
        box.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
    return (dy, box.size.height);
  }

  /// 目标块未构建时的**偏移估计**（文档坐标；无法估计返回 null）。
  ///
  /// 优先用**已构建区**做块序号外推，而不是全书字符比例：
  /// 字符比例 → 偏移的换算在插图页、标题块、表格处严重失真（字符多的一章
  /// 像素可能只占半屏）→ 粗跳落到错误位置 → 目标块始终构建不出来 → 定位
  /// 12 轮也不收敛（目录跳转偶发落到别的章）。
  ///
  /// 外推：以已构建区的高度 ÷ 块数 = 平均块高，按块序号差外推目标位置；
  /// 每跳一次，已构建区随之移动，下一轮的估计更准（相当于割线法收敛）。
  /// 外推不动（没有已构建区）时退回字符比例。
  double? _estimateOffset(int flat) {
    final max = _scrollController.position.maxScrollExtent;
    if (max <= 0) return null;
    final extent = _builtExtent();
    if (extent != null) {
      final (top, bottom, minIndex, maxIndex) = extent;
      final count = maxIndex - minIndex + 1;
      if (count > 0) {
        final avg = (bottom - top) / count;
        if (flat > maxIndex) {
          return (bottom + (flat - maxIndex) * avg).clamp(0.0, max);
        }
        if (flat < minIndex) {
          return (top - (minIndex - flat) * avg).clamp(0.0, max);
        }
      }
    }
    if (_totalChars <= 0) return null;
    final i = flat.clamp(0, _blocks.length - 1);
    return ((_prefixChars[i] + _charOffset) / _totalChars * max).clamp(
      0.0,
      max,
    );
  }

  /// 已构建块的文档坐标区间（顶..底）与实际构建的块序号区间。
  ///
  /// 只统计**当前仍挂在树上**的块（惰性窗口外的块已被回收，
  /// [_builtMin]/_[_builtMax] 是历史最大值，不能直接当区间用）。
  (double top, double bottom, int minIndex, int maxIndex)? _builtExtent() {
    final viewportBox = _renderBoxOf(_viewportKey.currentContext);
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    if (!_scrollController.hasClients ||
        _scrollController.positions.length != 1) {
      return null;
    }
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final base = _scrollController.offset;
    double? top;
    double? bottom;
    int? minIndex;
    int? maxIndex;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _renderBoxOf(_keys[i].currentContext);
      if (box == null || !box.attached || !box.hasSize) continue;
      final t = base + box.localToGlobal(Offset.zero).dy - viewportTop;
      final b = t + box.size.height;
      if (top == null || t < top) top = t;
      if (bottom == null || b > bottom) bottom = b;
      minIndex ??= i;
      maxIndex = i;
    }
    if (top == null || bottom == null || minIndex == null || maxIndex == null) {
      return null;
    }
    return (top, bottom, minIndex, maxIndex);
  }

  /// 滚动监听：更新逻辑位置（节流上报），并排帧末复测自校正
  /// （程序化滚动早于布局生效时，布局收敛后自动停止）。
  void _handleScroll() {
    if (_disposed) return;
    // 滚动后惰性窗口会构建新块 → 页停候选表需刷新：由视口的绘制前测量
    // 帧末复测（见 [scheduleStopRefresh]）。
    // 但列表视图自带 repaint boundary，滚动时本视口未必被标脏 → 显式请它
    // 重绘，否则裁剪会停在旧值（页尾半行又露出来）。
    _viewportRenderObject?.requestRepaint();
    // 滚动后惰性窗口会构建新块 → 页停候选表需刷新（帧末，见
    // [scheduleStopRefresh]）。
    scheduleStopRefresh();
    if (_locating) return;
    _settledIndex = -1;
    _updateFromViewport();
    _scheduleRecheck();
  }

  void _scheduleRecheck() {
    if (_recheckScheduled || _disposed) return;
    _recheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recheckScheduled = false;
      if (_disposed) return;
      final index = _updateFromViewport();
      if (index == null || index == _settledIndex) return;
      _settledIndex = index;
      _scheduleRecheck();
    });
  }

  /// 用当前视口测量刷新逻辑位置：当前块 = 视口顶所在块（跨视口顶的块优先），
  /// 块内偏移 = 视口顶深入该块的像素比例 × 块纯文本长度。返回可见块下标
  /// （测不到为 null）。只在位置变化时节流上报。
  int? _updateFromViewport({bool force = false}) {
    if (_disposed || _blocks.isEmpty) return null;
    final viewportBox = _renderBoxOf(_viewportKey.currentContext);
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _renderBoxOf(_keys[i].currentContext);
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom > viewportTop + 1 && top < viewportBottom - 1) {
        final height = box.size.height;
        final frac = height > 0
            ? ((viewportTop - top) / height).clamp(0.0, 1.0)
            : 0.0;
        final offset = (frac * _blocks[i].plainText.length).round();
        if (force || i != _flatIndex || offset != _charOffset) {
          _flatIndex = i;
          _charOffset = offset;
          _scheduleProgressReport();
        }
        return i;
      }
    }
    return null;
  }

  void _noteBuilt(int index) {
    if (index < _builtMin) _builtMin = index;
    if (index > _builtMax) _builtMax = index;
  }

  // —— 契约：视图与销毁 ——

  @override
  Widget buildView(BuildContext context) => _EpubViewHost(renderer: this);

  /// 构建单块视图（面板 itemBuilder 委托），构建后记入惰性测量窗口。
  ///
  /// [pageMode] + [viewportHeight]：page 模式下图片块改为**整页槽**——
  /// 每张插图独占一个吸附页（漫画 epub 的核心诉求：整页扫描图不再被
  /// 视口裁成两屏）。viewportHeight = 吸附单位（视口高）。
  ///
  /// [key]：翻页动画的**目标页窗口**会复制一份块（同一内容同时出现在
  /// 当前页与推入页两个窗口里），复制件必须用**不同的 key**——主副本用
  /// [_keys]（GlobalKey，供测量取盒），复制件用调用方给的独立 key。
  Widget buildBlock(
    BuildContext context,
    int index, {
    bool pageMode = false,
    double viewportHeight = 0,
    Key? key,
  }) {
    _noteBuilt(index);
    final block = _blocks[index];
    final colors = themeColors;
    final baseStyle = bodyTextStyle();

    Widget content;
    switch (block.kind) {
      case EpubBlockKind.hr:
        content = Divider(
          height: _settings.fontSize,
          thickness: 0.8,
          color: colors.dim,
        );
      case EpubBlockKind.listItem:
        content = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _settings.fontSize * 1.8,
              child: Text(block.listMarker, style: baseStyle),
            ),
            Expanded(child: _buildHtml(block.html, baseStyle, colors)),
          ],
        );
      case EpubBlockKind.quote:
        content = Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.only(left: 12, right: 4, top: 2, bottom: 2),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(width: 3, color: colors.dim)),
          ),
          child: _buildHtml(block.html, baseStyle, colors),
        );
      case EpubBlockKind.heading:
        content = Padding(
          padding: EdgeInsets.only(
            top: index == 0 ? 0 : _settings.fontSize * 0.6,
          ),
          child: _buildHtml(block.html, baseStyle, colors), // hN 自带标题缩放
        );
      case EpubBlockKind.image:
        // 图片自绘：fwfh 的 <img> 按原始像素尺寸绘制（漫画整页图 1225×1800
        // 会超出列宽被裁），这里统一解码 data URI 后用 Image.memory +
        // BoxFit.contain 受列宽约束。
        content = _EpubImage(
          key: ValueKey('epub-img-$index'),
          renderer: this,
          block: block,
          index: index,
          pageMode: pageMode,
          viewportHeight: viewportHeight,
        );
      case EpubBlockKind.paragraph:
        // 纯图片块（无文字 + 含 img）：漫画 epub 的整页扫描图多为
        // `<svg><image>`（已转为 `<div><img></div>`）或 `<div><img></div>`；
        // 走 fwfh 会按**原始像素尺寸**绘制（1225×1800），超出正文列宽被
        // 裁成两半。解析层契约不变（仍是 paragraph 块），这里在渲染层
        // 接管：page 模式整图独占一页，scroll 模式按列宽 contain 完整显示。
        if (_isImageOnlyBlock(block)) {
          content = _EpubImage(
            key: ValueKey('epub-img-$index'),
            renderer: this,
            block: block,
            index: index,
            pageMode: pageMode,
            viewportHeight: viewportHeight,
          );
          break;
        }
        // 裸文本块（无 html 片段）：转义后交给 HtmlWidget；正文段落统一
        // 两端对齐 + 首行缩进（A10，标题/列表/引用/图片不经此分支）。
        final html = block.html.isEmpty
            ? _escapeHtml(block.plainText)
            : block.html;
        content = _buildHtml(_wrapParagraph(html), baseStyle, colors);
      case EpubBlockKind.other:
        content = _buildHtml(block.html, baseStyle, colors);
    }
    // 图片整页槽：块尾距会破坏「槽高 = 视口高 − 2×页边距」的对齐，
    // 故 page 模式不加块尾距。
    final tailPadding = block.kind == EpubBlockKind.image && pageMode
        ? EdgeInsets.zero
        : EdgeInsets.only(bottom: _settings.fontSize * 0.35);
    return KeyedSubtree(
      key: key ?? _keys[index],
      // 块渲染盒登记（测量用）：挂到树上时登记，离开树时注销——测量因此
      // 不用遍历 GlobalKey 的 context（重建期可能已失活）。
      child: Padding(padding: tailPadding, child: content),
    );
  }

  /// 块是否为「纯图片块」（无文字 + 内含 img 标签）。
  static bool _isImageOnlyBlock(EpubBlock block) =>
      block.plainText.trim().isEmpty && block.html.contains('<img');

  /// 逐块 HtmlWidget：同步构建（首帧测量/测试确定性），基础样式随设置，
  /// 渲染错误（含图片解码失败）降级为错误占位，不崩渲染。
  Widget _buildHtml(String html, TextStyle baseStyle, EpubThemeColors colors) {
    if (html.trim().isEmpty) return const SizedBox.shrink();
    return HtmlWidget(
      html,
      buildAsync: false,
      textStyle: baseStyle,
      onErrorBuilder: (_, element, _) =>
          _errorPlaceholder(colors, element.attributes['alt']),
    );
  }

  /// 正文段落包装（A10）：外层 div 注入 `text-align: justify`（fwfh 支持
  /// 该 CSS 并继承到内联内容），段首插入 2em 全角空格作首行缩进（fwfh 无
  /// text-indent 样式，全角空格是等价实现）。只改显示层，不改 plainText
  /// 与块内字符偏移（locator 兼容性不受影响）。
  static String _wrapParagraph(String innerHtml) =>
      '<div style="text-align: justify">$epubParagraphIndent$innerHtml</div>';

  Widget _errorPlaceholder(EpubThemeColors colors, String? alt) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: colors.dim),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.image_not_supported_outlined, color: colors.dim, size: 28),
        if (alt != null && alt.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            alt,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: colors.dim),
          ),
        ],
      ],
    ),
  );

  static String _escapeHtml(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pendingReport?.cancel();
    _pendingReport = null;
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    controller.dispose();
  }
}

/// 图片块视图（自绘，替代 fwfh 的 <img>）。
///
/// - **scroll 模式**：按列宽 `BoxFit.contain` 完整显示（不再被原始像素
///   尺寸撑出列宽被裁）；
/// - **page 模式**：整页槽——每张插图独占一个吸附页（漫画 epub 核心诉求：
///   整页扫描图不再被前后两个吸附页各裁一半）。
///
/// 页界对齐（page 模式）：page 模式的吸附页界是**行边界页停**（不是视口高
/// 整数倍，见 [EpubRenderer._nextStop]），图片块作为原子单位参与页停计算：
/// 渲染器把「图片块块顶」登记为页停候选，并保证页界不落在图片块内部——
/// 于是图片块顶天然就是一页的起点，图片整页显示、页尾留白（视口高 −
/// 槽高 − 段距）。槽高固定为「视口高 − 2×页边距」，故块高恒 ≤ 一页，
/// 图片不会被页界切开。
class _EpubImage extends StatefulWidget {
  const _EpubImage({
    super.key,
    required this.renderer,
    required this.block,
    required this.index,
    required this.pageMode,
    required this.viewportHeight,
  });

  final EpubRenderer renderer;
  final EpubBlock block;
  final int index;

  /// page 模式（整页槽）还是 scroll 模式（列宽内完整显示）。
  final bool pageMode;

  /// 吸附单位（视口高；page 模式用）。
  final double viewportHeight;

  @override
  State<_EpubImage> createState() => _EpubImageState();
}

class _EpubImageState extends State<_EpubImage> {
  @override
  Widget build(BuildContext context) {
    final r = widget.renderer;
    final colors = r.themeColors;
    final margin = r.settings.pageMargin;
    final bytes = r.decodeImageBytes(widget.index, widget.block.html);
    final alt = widget.block.plainText.trim();
    final Widget child;
    if (bytes != null) {
      child = Image.memory(
        bytes,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) =>
            r._errorPlaceholder(colors, alt.isNotEmpty ? alt : null),
      );
    } else {
      child = r._errorPlaceholder(colors, alt.isNotEmpty ? alt : null);
    }
    if (!widget.pageMode) {
      // scroll 模式：按列宽完整显示（宽度约束来自父级，contain 不裁切）。
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: double.infinity, child: child),
      );
    }
    final v = widget.viewportHeight > 0 ? widget.viewportHeight : 600.0;
    final slotH = (v - 2 * margin).clamp(120.0, v);
    // 槽顶 = 块顶 = 页停（渲染器把图片块块顶登记为页停候选）→ 图片自页面
    // 顶部起完整显示，页尾留白由视口裁剪补齐。
    return SizedBox(height: slotH, width: double.infinity, child: child);
  }
}

// ============================================================================
// 控制器
// ============================================================================

/// [ReaderController] 的 epub 实现，全部转发渲染会话。
class EpubReaderController extends ReaderController {
  EpubReaderController._(this._r);

  final EpubRenderer _r;

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
  }
}

// ============================================================================
// 视图
// ============================================================================

/// 视图宿主：背景随主题；revision 驱动重建；排版几何/翻页模式变化 →
/// 面板整体重建（重建后按当前块 + 块内偏移复位位置）。
class _EpubViewHost extends StatelessWidget {
  const _EpubViewHost({required this.renderer});

  final EpubRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: renderer._revision,
      builder: (context, _, _) {
        final colors = renderer.themeColors;
        final mode = renderer.settings.pageMode;
        return Container(
          key: renderer.viewportKey,
          color: colors.background,
          child: KeyedSubtree(
            // key 变了 → 内容面板**整体重建**（翻页方式切换 / 排版几何变化
            // 都要换一套视图结构）。重建会连带把滚动视图也换掉 → 滚动偏移
            // 必须由正文列表自己挂 [PageStorageKey] 保留（见
            // [_epubBodyStorageKey]），否则新视图从 0 起（画面闪回封面）。
            key: ValueKey('epub-${mode.name}-${renderer._layoutEpoch}'),
            child: renderer.blockCount == 0
                ? Center(
                    child: Text('（无正文内容）', style: TextStyle(color: colors.dim)),
                  )
                : _EpubContentPane(renderer: renderer),
          ),
        );
      },
    );
  }
}

/// 内容面板：scroll = 滚动；page = 同一连续内容 + **行边界页停**吸附翻页
/// （连续排版、翻页不重解析，docs/07-R2 登记方案；页界落点见
/// [EpubRenderer._nextStop]——落在行与行之间，不切字）。
class _EpubContentPane extends StatefulWidget {
  const _EpubContentPane({required this.renderer});

  final EpubRenderer renderer;

  @override
  State<_EpubContentPane> createState() => _EpubContentPaneState();
}

class _EpubContentPaneState extends State<_EpubContentPane>
    with SingleTickerProviderStateMixin {
  /// 翻页动画控制器（松手后补完/回弹；时长与缓动取自
  /// [ReaderPageTurnSpec]，与 txt 等格式一致）。
  late final AnimationController _turnAnim = AnimationController(
    vsync: this,
    duration: ReaderPageTurnSpec.duration,
  );

  /// 跟手拖拽模型：位移 → 翻页进度（纯逻辑，见 [ReaderPageTurnDrag]）。
  final ReaderPageTurnDrag _drag = ReaderPageTurnDrag();

  /// 翻页进度：0 = 当前页在位；1 = 下一页完全推入；-1 = 上一页完全推入。
  double _s = 0;

  /// 推入页的页起点（文档坐标）；null = 当前没有推入页。
  double? _incomingStart;

  /// 动画起止值（缓动施加在 [_onTurnTick]）。
  double _animFrom = 0;
  double _animTo = 0;

  /// 动画是否在飞（动画中再次翻页 → 直接落到最终目标，不排队）。
  bool _turning = false;

  /// 视口尺寸（位移 → 进度换算；build 时记录）。
  double _viewportWidth = 0;
  double _viewportHeight = 0;

  @override
  void initState() {
    super.initState();
    _turnAnim
      ..addListener(_onTurnTick)
      ..addStatusListener(_onTurnStatus);
    // page 模式的翻页动画由本面板播放（统一左右推移，docs/10 §9.21）；
    // scroll 模式不注册（滚动模式的翻页 = 滚一屏，由渲染器自己做）。
    if (widget.renderer.settings.pageMode == ReaderPageMode.page) {
      widget.renderer._turnDelegate = _turn;
    }
    // 首帧后按渲染器当前逻辑位置定位（restore 可能早于视图创建发生）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.renderer.locateFromView();
    });
  }

  @override
  void dispose() {
    _turnAnim.dispose();
    if (identical(widget.renderer._turnDelegate, _turn)) {
      widget.renderer._turnDelegate = null;
    }
    super.dispose();
  }

  /// page 模式：**吞掉滚轮事件**（不翻页，正文也不因滚轮而动）。
  ///
  /// v1.3.7：分页模式的翻页**只由键盘**（↑/↓/PageUp/PageDown/空格）与
  /// **左右滑动**控制——滚轮在分页模式下既不翻页也不滚动（用户实测：分页模式
  /// 下用滚轮会乱翻）。
  ///
  /// 监听挂在**每个块项内部**——PointerSignalResolver 采用最深（最先注册）
  /// 的回调，抢先注册后 Scrollable 不再收到滚轮（否则滚轮会在分页正文里
  /// 自由滚动，页界随之失效）。
  void _swallowWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      // 标记事件已处理：Scrollable 不得再用滚轮滚动正文。
      (event as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
  }

  // —— 翻页动画（左右推移，v1.4.4 / docs/10 §9.21）——

  /// 动画每帧：把控制器进度按统一缓动映射到翻页进度 [_s]。
  void _onTurnTick() {
    if (!mounted) return;
    final t = ReaderPageTurnSpec.curve.transform(_turnAnim.value);
    final s = _animFrom + (_animTo - _animFrom) * t;
    widget.renderer.reportTurnProgress(s);
    setState(() => _s = s);
  }

  /// 动画结束：提交落点（翻页成功）或复位（取消）。
  void _onTurnStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _settleTurn();
  }

  /// 翻页收尾：落点写进页起点链并跳转（提交），随后复位到静止态。
  void _settleTurn() {
    _turning = false;
    final landing = _incomingStart;
    final target = _animTo;
    if (landing != null && target != 0) {
      widget.renderer.commitPageStart(landing);
    }
    widget.renderer.reportTurnProgress(0);
    if (!mounted) return;
    setState(() {
      _s = 0;
      _incomingStart = null;
      _animTo = 0;
    });
  }

  /// 翻页（键盘 / 热区 / 音量键）：与左右滑动**同一套**动画。
  ///
  /// 目标页准备 → 横向推移 → 动画收尾时提交落点（页起点链 + 跳转）。
  Future<bool> _turn(int delta) {
    if (_turning) {
      // 动画中再次翻页：当前动画直接落到终点（提交落点），再开始新的翻页
      // ——不得让动画中途的位置被覆盖而跳错页（docs/10 §9.21 §3.3）。
      _turnAnim.stop();
      _settleTurn();
    }
    final started = widget.renderer.requestTurn(delta, (target) {
      _startTurn(delta, target);
    });
    return Future.value(started);
  }

  /// 起翻：准备推入页窗口 → 播放推移动画。
  void _startTurn(int delta, double target) {
    if (!mounted) return;
    _incomingStart = target;
    _animFrom = 0;
    _animTo = delta > 0 ? 1 : -1;
    _turning = true;
    setState(() {});
    _turnAnim
      ..reset()
      ..forward();
  }

  // —— 跟手拖拽（左右滑动）——

  /// 拖拽开始：停掉在飞的补完动画，从静止态重新跟手。
  void _onDragStart(DragStartDetails details) {
    _turnAnim.stop();
    _turning = false;
    _drag.reset();
    if (!mounted) return;
    setState(() {
      _s = 0;
      _incomingStart = null;
    });
  }

  /// 拖拽中：位移 1:1 映射到翻页进度（跟手），并准备推入页窗口。
  void _onDragUpdate(DragUpdateDetails details) {
    final width = _viewportWidth;
    if (width <= 0) return;
    _drag.update(details.primaryDelta ?? 0);
    final s = _drag.progress(width);
    _ensureIncoming(s);
    widget.renderer.reportTurnProgress(s);
    if (!mounted) return;
    setState(() => _s = s);
  }

  /// 松手：过阈值补完到目标页，不过阈值弹回原页。
  void _onDragEnd(DragEndDetails details) {
    final width = _viewportWidth;
    if (width <= 0) return;
    switch (_drag.decide(width)) {
      case ReaderPageTurnOutcome.next:
        if (_incomingStart == null) {
          _settleTo(0);
          return;
        }
        _settleTo(1);
      case ReaderPageTurnOutcome.previous:
        if (_incomingStart == null) {
          _settleTo(0);
          return;
        }
        _settleTo(-1);
      case ReaderPageTurnOutcome.cancel:
        _settleTo(0);
    }
  }

  /// 补完 / 回弹动画（统一时长与缓动）。
  void _settleTo(double target) {
    _animFrom = _s;
    _animTo = target;
    _turning = true;
    _turnAnim
      ..reset()
      ..forward();
  }

  /// 拖拽方向确定后准备**推入页**（目标页起点 + 窗口高度）。
  ///
  /// 方向未定（位移过小）时不准备——推入页在屏幕外，迟一帧出现无感。
  void _ensureIncoming(double s) {
    if (_incomingStart != null) return;
    if (s.abs() < 0.02) return;
    final delta = s > 0 ? 1 : -1;
    final target = widget.renderer.pageTurnTargetFor(delta);
    if (target == null) return;
    _incomingStart = target;
  }

  /// 推入页窗口（目标页的**复制渲染**）。
  ///
  /// epub 的「页」不是独立内容，而是连续排版上的一个偏移区间——要让当前页
  /// 与目标页**同时可见**（横向推移的交接），只能把目标页覆盖的块复制一
  /// 份渲染。复制件用独立 key（主副本的 GlobalKey 仍只归测量用），因此
  /// 行盒测量、页停候选、插图独占页等既有成果全部不受影响。
  ///
  /// 窗口高度 = **一整屏**，页界由 [_EpubIncomingViewport] 在**绘制阶段**
  /// 现算（与主视口同一口径、同一保守兜底）——见该类注释。
  Widget _buildIncomingWindow(double horizontal) {
    final r = widget.renderer;
    final start = _incomingStart;
    if (start == null) return const SizedBox.shrink();
    // 目标页覆盖的块区间（按保守口径的页高取；绘制阶段还会现算一次裁剪线）。
    final pageHeight = r.pageContentHeightAt(start, _viewportHeight);
    if (pageHeight <= 0) return const SizedBox.shrink();
    final range = r.pageWindowBlocks(start, start + pageHeight);
    if (range == null) return const SizedBox.shrink();
    final (first, last, firstTop) = range;
    return Listener(
      // 推入页盖在正文之上：滚轮仍要被吞掉（分页模式滚轮既不翻页也不滚动）。
      onPointerSignal: _swallowWheel,
      behavior: HitTestBehavior.opaque,
      child: _EpubIncomingViewport(
        renderer: r,
        start: start,
        background: r.themeColors.background,
        child: SizedBox(
          height: _viewportHeight,
          width: double.infinity,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontal),
            child: Stack(
              // 目标页只是连续排版的一个**窗口**：块列可以比窗口高（页尾的块
              // 只露一半），故用 Stack + hardEdge 裁剪，而不是给列一个有限
              // 高度（那样会 RenderFlex overflow）。
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: Transform.translate(
                    // 把目标页起点对到窗口顶（首块顶在目标页起点之上）。
                    offset: Offset(0, -(start - firstTop)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = first; i <= last; i++)
                          r.buildBlock(
                            context,
                            i,
                            pageMode: true,
                            viewportHeight: _viewportHeight,
                            key: ValueKey('epub-incoming-$i'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.renderer;
    final isPage = r.settings.pageMode == ReaderPageMode.page;
    // 面板重建（排版几何变化/翻页模式切换）后行盒与页停需重测。
    r.scheduleStopRefresh();
    // 正文列宽上限 720（A10）：宽屏水平留白居中，窄屏保持页边距。
    return LayoutBuilder(
      builder: (context, constraints) {
        final margin = r.settings.pageMargin;
        final horizontal = math.max(
          margin,
          (constraints.maxWidth - AppLayout.readerMaxWidth) / 2,
        );
        final list = ListView.builder(
          controller: r.scrollController,
          // **滚动偏移跨视图重建保留**（见 [_EpubViewHost] 的 KeyedSubtree
          // 注释）：翻页方式切换会重建整个正文视图（分页视图的包装结构与
          // 滚动视图不同），若偏移不随视图保留，新视图从 0 起——画面先闪回
          // 第一页/封面，之后渲染器再按逻辑位置把位置找回来（中间那几帧正文
          // 还没建出来 = 加载不全，翻一次页才恢复）。
          //
          // 框架只在滚动视图挂了 [PageStorageKey] 时才保存/恢复偏移（见
          // ScrollPosition.restoreScrollOffset）；key 固定 → 重建前后是同一个
          // 存储槽 → 偏移被原样接回，切换那一帧就已在阅读位置。
          key: _epubBodyStorageKey,
          // scroll 模式：甩动位移封顶（阅读要可控，见 reader_scroll_physics）。
          // page 模式：按页起点吸附（一次滑动 = 一页）。
          physics: isPage
              ? EpubPageScrollPhysics(renderer: r)
              : const ReaderScrollPhysics(),
          // page 模式要多**预建两屏**（用户诉求「提前渲染前后 2-3 页」）：
          // ① 下一行边界页停落在「当前落点 + 一屏」附近，落在惰性窗口之外就
          //    量不到；② 翻页时**推入页**要复制渲染目标页的块——目标页落在
          //    「当前落点 + 一屏 ~ 两屏」之间，只预建一屏时它恰好卡在惰性
          //    窗口的边界上，末尾几行常常还没构建 → 推入页要么空白、要么按
          //    满一屏裁（露出被拦腰截断的半行）。
          // 预建两屏后，目标页的块与行落点**总是**已就绪：推入页有内容，
          // 页界候选也已知（页尾留白而不是切字）。
          scrollCacheExtent: isPage
              ? ScrollCacheExtent.pixels(constraints.maxHeight * 2)
              : null,
          padding: EdgeInsets.symmetric(
            horizontal: horizontal,
            vertical: margin,
          ),
          itemCount: r.blockCount,
          itemBuilder: (context, index) {
            final child = r.buildBlock(
              context,
              index,
              pageMode: isPage,
              viewportHeight: constraints.maxHeight,
            );
            if (!isPage) return child;
            // 滚轮监听必须挂在块项**内部**（比 Scrollable 深）才能在
            // PointerSignalResolver 竞争中抢先注册，见 _swallowWheel 注释。
            return Listener(
              onPointerSignal: _swallowWheel,
              behavior: HitTestBehavior.opaque,
              child: child,
            );
          },
        );
        if (!isPage) return list;
        // page 模式（分页视图）**不挂框架自动滚动条**。
        //
        // 原因：滚动条滑块的长度与位置来自惰性列表的**估算**总高——未构建的
        // 块按原型估高、离开惰性窗口被回收的块退回估高。epub 的块高差异
        // 极大（整页插图 ≈500px、普通段落 ≈50px），于是每翻一页（构建/回收
        // 一批块）总高估计就跳变数百像素 → 滑块一边变长一边跳位，正是用户
        // 实测的「往下翻页时右侧滚动条上下挑动」。
        //
        // 分页视图里像素级滚动条本就没有意义（翻页是离散的，拖滚动条也无法
        // 定位到"第几页"），阅读位置由阅读器底部的进度轨承载（与 txt 分页
        // 的 PageView 一致：分页视图本就没有滚动条）。
        //
        // 注意：[ScrollBehavior.copyWith] 会把 delegate 原样包一层
        // （_WrappedScrollBehavior），应用自定义的 dragDevices（桌面鼠标
        // 拖拽）仍然生效——这里只关 scrollbars。
        _viewportWidth = constraints.maxWidth;
        _viewportHeight = constraints.maxHeight;
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            // 分页模式：**不接受鼠标拖动**（见 kReaderTouchOnlyDragDevices）——
            // 鼠标拖动会把正文在页中间拖着走，页界随之失效。
            dragDevices: kReaderTouchOnlyDragDevices,
          ),
          // **左右推移**（v1.4.4，docs/10 §9.21）：双窗口交接——
          // 槽 A = 当前页（连续列表 + 页尾裁剪），槽 B = 推入页（目标页的
          // 复制窗口）。当前页向左推出、推入页自右推入，位移 1:1 跟手。
          //
          // 只认触摸（鼠标手势在分页模式已全部禁用）；正文不再随手指上下滑动
          // （page 模式禁止用户滚动）→ 手势与页界互不干扰。
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              HorizontalDragGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    HorizontalDragGestureRecognizer
                  >(
                    () => HorizontalDragGestureRecognizer(
                      supportedDevices: kReaderTouchOnlyDragDevices,
                    ),
                    (recognizer) {
                      recognizer.onStart = _onDragStart;
                      recognizer.onUpdate = _onDragUpdate;
                      recognizer.onEnd = _onDragEnd;
                    },
                  ),
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 槽 A：当前页。向左推出（s > 0）/ 向右让位（s < 0）。
                Transform.translate(
                  offset: Offset(-constraints.maxWidth * _s, 0),
                  child: _EpubPageViewport(renderer: r, child: list),
                ),
                // 槽 B：推入页。自右推入（s > 0）/ 自左推入（s < 0）。
                if (_incomingStart != null)
                  Transform.translate(
                    offset: Offset(
                      constraints.maxWidth * (1 - _s.abs()) * (_s < 0 ? -1 : 1),
                      0,
                    ),
                    child: _buildIncomingWindow(horizontal),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// page 模式视口：按「本页终点」裁剪内容（页界不切字 + 不闪）。
///
/// **为什么不用 `ClipRect(clipper:)`**（旧实现，两个坑叠在一起）：
///
/// 1. 框架的 [RenderCustomClip] 会**缓存**裁剪矩形——`getClip` 只在缓存失效
///    时才重算，而自定义 clipper 不会自动通知失效。于是裁剪矩形会一直停在
///    第一次算出来的值（首帧还没有行盒，多半是整屏）→ 页尾的半行/半图
///    **始终露着**，页界等于没裁。
/// 2. 旧实现把页终点测量放在**帧末**（post-frame）：画这一帧时用的是上一帧
///    的旧落点 → 翻页/跳转瞬间先露出被切断的半行，收紧时又消失 → 闪一下。
///
/// 本实现不用 CustomClipper：裁剪矩形**每帧在绘制阶段现算**（数据来自帧末
/// 实测的页停候选；page 模式多预建一屏，下一页的落点已提前量到）→
/// 页界永远落在行与行之间，且「先露半行再收紧」的闪烁从根上消失。
class _EpubPageViewport extends SingleChildRenderObjectWidget {
  const _EpubPageViewport({required this.renderer, required super.child});

  final EpubRenderer renderer;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEpubPageViewport(renderer);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderEpubPageViewport).renderer = renderer;
  }
}

class _RenderEpubPageViewport extends RenderProxyBox {
  _RenderEpubPageViewport(this._renderer);

  EpubRenderer _renderer;

  set renderer(EpubRenderer value) {
    if (identical(_renderer, value)) return;
    _renderer = value;
    markNeedsPaint();
  }

  /// 请求重绘（滚动后裁剪要跟着内容走）。
  ///
  /// 列表视图自带 repaint boundary：滚动时它自己重绘，祖先（本视口）未必
  /// 被标脏 → 裁剪矩形会停在旧值（页尾的半行/半图又露出来）。故滚动时由
  /// 渲染器显式请本对象重绘。
  void requestRepaint() => markNeedsPaint();

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _renderer._viewportRenderObject = this;
  }

  @override
  void detach() {
    if (identical(_renderer._viewportRenderObject, this)) {
      _renderer._viewportRenderObject = null;
    }
    super.detach();
  }

  /// 当帧的裁剪高度（视口顶 → 本页终点）。
  double _clipHeight = 0;

  @override
  void performLayout() {
    child!.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child!.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // 裁剪高度在**绘制阶段**现算：框架的 CustomClipper 会缓存裁剪矩形，
    // 旧实现因此永远停在首帧算出的值（多半是整屏）→ 页尾的半行/半图一直
    // 露着。这里不用 CustomClipper，矩形每帧重算。
    _renderer.noteViewportHeight(size.height);
    _clipHeight = _renderer.pageContentHeight(size.height);
    final rect = Rect.fromLTWH(0, 0, size.width, _clipHeight);
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      rect,
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: layer as ClipRectLayer?,
    );
  }

  /// 命中测试**不**受裁剪约束：页尾留白（甚至整页留白）时控件仍可点，
  /// 不会出现「页面空白 → 点不动」。
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      super.hitTest(result, position: position);
}

/// 推入页视口：在**绘制阶段**现算页界，按页终点裁掉页尾的半行/半图。
///
/// 与主视口 [_EpubPageViewport] 同口径、同兜底（页终点 → 安全边界 → 内容
/// 末尾 → 留白），区别只在于「起点」是**推入页的页起点**而非当前滚动位置。
///
/// 旧实现是「固定高度的窗口 + ClipRect」：高度在起翻瞬间算一次就**冻住**，
/// 且候选未知时直接给满**一屏** → ① 切线落在任意 y 上，页尾露出被拦腰截断
/// 的一行（用户实测「左右翻页渲染时还是会有 1 瞬间被截断的行出现」）；② 高度
/// 与最终落点的页界不一致，收尾时页面会跳一下。
///
/// 这里把裁剪高度改成**每帧现算**（与主视口同一套保守兜底），从根上消掉
/// 「被截断的行」；同时在裁剪线以下铺阅读底色，避免正在退场的旧页从推入页
/// 下方透出来（横向推移时两页并排，看着像多了一行没裁掉的字）。
class _EpubIncomingViewport extends SingleChildRenderObjectWidget {
  const _EpubIncomingViewport({
    required this.renderer,
    required this.start,
    required this.background,
    required super.child,
  });

  final EpubRenderer renderer;

  /// 推入页的页起点（文档坐标）。
  final double start;

  /// 阅读底色（裁剪线以下铺它，遮住退场的旧页）。
  final Color background;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderEpubIncomingViewport(renderer, start, background);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    final ro = renderObject as _RenderEpubIncomingViewport;
    ro.renderer = renderer;
    ro.start = start;
    ro.background = background;
  }
}

class _RenderEpubIncomingViewport extends RenderProxyBox {
  _RenderEpubIncomingViewport(this._renderer, this._start, this._background);

  EpubRenderer _renderer;
  double _start;
  Color _background;

  set renderer(EpubRenderer value) {
    if (identical(_renderer, value)) return;
    _renderer = value;
    markNeedsPaint();
  }

  set start(double value) {
    if (_start == value) return;
    _start = value;
    markNeedsPaint();
  }

  set background(Color value) {
    if (_background == value) return;
    _background = value;
    markNeedsPaint();
  }

  /// 当帧的裁剪高度（推入页起点 → 该页终点）。
  double _clipHeight = 0;

  /// 底色画笔（裁剪线以下铺底色用；复用，避免每帧新建）。
  final Paint _backgroundPaint = Paint();

  @override
  void performLayout() {
    child!.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(child!.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // 裁剪高度在**绘制阶段**现算（数据来自帧末实测的页停候选）：旧实现把
    // 高度冻在起翻瞬间，候选未知时还是满一屏 → 页尾的半行露出来又消失。
    _clipHeight = _renderer.pageContentHeightAt(_start, size.height);
    // 裁剪线以下先铺阅读底色：否则正在退场的旧页会从推入页下方透出来
    // （横向推移时两页并排，看着像「多了一行没被裁掉的字」）。
    _backgroundPaint.color = _background;
    context.canvas.drawRect(offset & size, _backgroundPaint);
    final rect = Rect.fromLTWH(0, 0, size.width, _clipHeight);
    layer = context.pushClipRect(
      needsCompositing,
      offset,
      rect,
      super.paint,
      clipBehavior: Clip.hardEdge,
      oldLayer: layer as ClipRectLayer?,
    );
  }
}

/// page 模式物理：**不接受用户滚动**（翻页由键盘与左右滑动驱动）。
///
/// v1.3.7 用户决定：移动端分页模式由「上下滑动」改为「左右滑动」，正文
/// 不再随手指上下滑动（滑动会把正文拖到页中间 → 页界与可见内容对不齐）。
/// 页面按**页起点**裁剪显示（页界不切字；插图独占一页），翻页 = 跳到相邻
/// 页起点（见 [EpubRenderer._turnPageInPageMode]）。
///
/// 公开类名：测试需要断言 page 模式用的是本物理（而非视口高吸附）。
class EpubPageScrollPhysics extends ScrollPhysics {
  const EpubPageScrollPhysics({required this.renderer, super.parent});

  final EpubRenderer renderer;

  @override
  EpubPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      EpubPageScrollPhysics(renderer: renderer, parent: buildParent(ancestor));

  /// page 模式**不接受用户滚动**（v1.3.7 用户决定）。
  ///
  /// 分页模式下正文按页裁剪显示（页界 = 页起点..下一页起点），用户滚动会
  /// 把正文拖到页中间 → 页界与可见内容对不齐。翻页改由**键盘**与
  /// **左右滑动**驱动（见 [_EpubContentPaneState._onDragUpdate]）。
  ///
  /// 置 false 的副作用：Scrollable 的 `setCanDrag(false)` → 拖拽识别器不再
  /// 参与手势竞技场（触摸滑动也不会带动正文 ✓，正是要的效果）；程序化滚动
  /// （`jumpTo`/`animateTo`：翻页、恢复进度、跳章）不受影响 ✓。
  @override
  bool shouldAcceptUserOffset(ScrollMetrics position) => false;

  @override
  bool get allowImplicitScrolling => false;
}
