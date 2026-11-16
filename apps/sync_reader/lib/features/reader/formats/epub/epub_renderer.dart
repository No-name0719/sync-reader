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
import 'package:flutter/rendering.dart' show ScrollCacheExtent, ScrollDirection;
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';

import '../../../../core/design_tokens.dart' show AppLayout;
import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_controller.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
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

/// spine 条目（解析产物：href + 该文件的块序列）。
class _SpineItem {
  const _SpineItem({required this.href, required this.blocks});

  /// 内容文件 href（manifest 原样形态，OPF 相对路径）。
  final String href;

  /// 块序列（可为空：文件缺失/纯图片无 alt 等）。
  final List<EpubBlock> blocks;
}

/// 某块的行盒缓存（块尺寸 + 块内行盒）：块布局未变则复用。
class _EpubBlockLines {
  const _EpubBlockLines(this.size, this.lines);

  /// 测量时的块尺寸（尺寸变了即重测）。
  final Size size;

  /// 块内行盒（块局部坐标）。
  final List<EpubLineBox> lines;

  /// 缓存是否仍对得上当前块尺寸。
  bool matches(Size current) =>
      current.height == size.height && current.width == size.width;
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
      await _locatePosition();
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
    await _locatePosition();
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
    await _locatePosition();
    _scheduleProgressReport();
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
    double target;
    if (_settings.pageMode == ReaderPageMode.page) {
      // page 模式：页起点落点（行边界；插图独占整页）。
      // 先用现测候选刷新页结构（翻页必须基于最新行盒——布局刚变时缓存是旧的）。
      _pages.viewport = viewport;
      _pages.setStops(_measureStops());
      final stop = delta > 0
          ? _pages.nextPageStart(ctrl.offset)
          : _pages.prevPageStart(ctrl.offset);
      target = stop ?? (ctrl.offset + delta * viewport);
    } else {
      // scroll 模式：一页/一屏 = 视口高度（连续滚动，不吸附）。
      target = ctrl.offset + delta * viewport;
    }
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    if ((clamped - ctrl.offset).abs() < 0.5) return Future.value(false);
    ctrl.jumpTo(clamped); // 触发 _handleScroll → 位置更新 + 节流上报
    return Future.value(true);
  }

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

  /// 行盒缓存：块下标 → (块尺寸, 块内行盒)。块布局未变则复用（引擎取行盒
  /// 较贵，翻页/滚动时每帧都会用到）。
  final Map<int, _EpubBlockLines> _lineCache = {};

  /// 页结构：页停候选（累积）+ 页起点链（走过的页起点）。
  ///
  /// 候选表跨滚动累积：离开惰性窗口的块不再重建，但其行盒位置依然有效——
  /// 「上一页」要能回到读过的地方。布局几何变化时整体作废（见
  /// [_invalidateLineCache]）。
  final EpubPageStructure _pages = EpubPageStructure(viewport: 600);


  /// 页停缓存刷新是否已排队。
  bool _stopRefreshScheduled = false;

  /// 安排帧末刷新页停候选（此时布局已定稿，可安全测量渲染树）。
  void scheduleStopRefresh() {
    if (_stopRefreshScheduled || _disposed) return;
    _stopRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopRefreshScheduled = false;
      if (_disposed) return;
      _pages.setStops(_measureStops());
    });
  }

  /// 行盒缓存失效（排版几何变化时）：行盒位置全变，重测。
  ///
  /// 页停候选与页起点链一并作废（几何变了，旧落点全部失效）。
  void _invalidateLineCache() {
    _lineCache.clear();
    _pages.clear();
  }

  /// 某块的行盒（块局部坐标）：块尺寸未变则复用缓存。
  List<EpubLineBox> _blockLineBoxes(int index, RenderBox box) {
    final cached = _lineCache[index];
    if (cached != null && cached.matches(box.size)) return cached.lines;
    final lines = measureEpubLineBoxes(box, baseFontSize: _settings.fontSize);
    _lineCache[index] = _EpubBlockLines(box.size, lines);
    return lines;
  }

  /// 页停候选（文档坐标，升序）——**现测**（须在布局阶段之外调用）。
  List<EpubStop> _measureStops() {
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return const [];
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final base =
        _scrollController.hasClients && _scrollController.positions.length == 1
        ? _scrollController.offset
        : 0.0;
    final stops = <EpubStop>[];
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final blockTop = base + box.localToGlobal(Offset.zero).dy - viewportTop;
      if (_isImageBlock(i)) {
        // 图片块 = **原子区间** [块顶, 块底]：页界不得落在其内部 → 插图
        // 独占一页（不会被切成两页各露一半）。块底同时登记为候选，插图页
        // 的下一页就从块底起。
        final bottom = blockTop + box.size.height;
        stops.add(EpubStop.image(blockTop, bottom));
        stops.add(EpubStop.text(bottom));
        continue;
      }
      for (final line in _blockLineBoxes(i, box)) {
        // 落点取「安全落点」（行盒顶上移余量），不是行盒顶——中日韩字面
        // 常高于字体 ascent 带，按行盒顶落点仍会削掉字形顶部。
        stops.add(EpubStop.text(blockTop + line.landing));
      }
    }
    stops.sort((a, b) => a.pos.compareTo(b.pos));
    return stops;
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
  /// 返回 [viewportHeight] 表示不裁剪（拖拽中/未挂载/无下一页起点）。
  double pageContentHeight(double viewportHeight) {
    if (_disposed || !_scrollController.hasClients) return viewportHeight;
    // 面板重建期可能短暂挂了两个滚动视图（同一 controller）→ 不取位置。
    if (_scrollController.positions.length != 1) return viewportHeight;
    if (_userScrolling) return viewportHeight; // 拖拽中：连续内容，不裁剪
    final offset = _scrollController.offset;
    _pages.viewport = viewportHeight;
    final next = _pages.peekNextPageStart(offset);
    if (next == null) return viewportHeight;
    return (next - offset).clamp(0.0, viewportHeight);
  }

  /// 用户是否正在拖动滚动（拖拽中不裁剪视口）。
  bool _userScrolling = false;

  /// 按全书比例跳转（[ReaderPercentJump] 契约；进度滑块用）：
  /// percent × 总字符 → 所在块（与降级恢复同一换算），块内偏移清零后定位。
  @override
  Future<void> jumpToPercent(double percent) async {
    if (_disposed || _blocks.isEmpty) return;
    final target = (percent.clamp(0.0, 1.0) * _totalChars).round();
    final flat = EpubPositionMath.flatIndexAtCharOffset(_prefixChars, target);
    _setPosition(flat, 0);
    await _locatePosition();
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
      final box = _keys[i].currentContext?.findRenderObject();
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
        // 目标块未构建（惰性窗口外）：按字符比例估算先跳，下一轮可测。
        final max = _scrollController.position.maxScrollExtent;
        if (max > 0 && _totalChars > 0) {
          final i = _flatIndex.clamp(0, _blocks.length - 1);
          final estimate = ((_prefixChars[i] + _charOffset) / _totalChars * max)
              .clamp(0.0, max);
          _scrollController.jumpTo(estimate);
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
    final box = _keys[flat].currentContext?.findRenderObject();
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final dy =
        box.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
    return (dy, box.size.height);
  }

  /// 滚动监听：更新逻辑位置（节流上报），并排帧末复测自校正
  /// （程序化滚动早于布局生效时，布局收敛后自动停止）。
  void _handleScroll() {
    if (_disposed) return;
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
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    for (var i = _builtMin; i <= _builtMax && i < _blocks.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject();
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
  Widget buildBlock(
    BuildContext context,
    int index, {
    bool pageMode = false,
    double viewportHeight = 0,
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
      key: _keys[index],
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
    return SizedBox(
      height: slotH,
      width: double.infinity,
      child: child,
    );
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

class _EpubContentPaneState extends State<_EpubContentPane> {
  /// 滚轮累积量（page 模式）：一档 ≈ 80–120 逻辑像素，过阈值翻一页并清零。
  double _wheelAccum = 0;

  @override
  void initState() {
    super.initState();
    // 首帧后按渲染器当前逻辑位置定位（restore 可能早于视图创建发生）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.renderer.locateFromView();
    });
  }

  /// page 模式滚轮翻页：一档滚轮 = 翻一页。监听挂在**每个块项内部**——
  /// PointerSignalResolver 采用最深（最先注册）的回调，抢先注册后
  /// Scrollable 不再收到滚轮的小幅滚动 + 回弹（原表现：一档滚不动缩回去）。
  /// 触控/鼠标拖拽翻页走手势竞技场，不受影响。
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      _wheelAccum += delta;
      const threshold = 60;
      if (_wheelAccum >= threshold) {
        _wheelAccum = 0;
        unawaited(widget.renderer.nextPage());
      } else if (_wheelAccum <= -threshold) {
        _wheelAccum = 0;
        unawaited(widget.renderer.previousPage());
      }
      // 标记事件已处理：祖先滚动视图不得再用平台默认行为响应它。
      (event as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
  }

  /// 拖拽状态跟踪：拖动中视口不按页停裁剪（保持连续内容的观感）。
  bool _onUserScroll(UserScrollNotification notification) {
    widget.renderer._userScrolling =
        notification.direction != ScrollDirection.idle;
    return false;
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
          physics: isPage ? EpubPageScrollPhysics(renderer: r) : null,
          // page 模式要多预建一屏：下一行边界页停落在「当前落点 + 一屏」
          // 附近，落在惰性窗口之外就量不到。
          scrollCacheExtent: isPage
              ? ScrollCacheExtent.pixels(constraints.maxHeight)
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
            // PointerSignalResolver 竞争中抢先注册，见 _onWheel 注释。
            return Listener(
              onPointerSignal: _onWheel,
              behavior: HitTestBehavior.opaque,
              child: child,
            );
          },
        );
        if (!isPage) return list;
        // page 模式：视口按「本页内容高度」裁剪——页尾留白（不足一行），
        // 不把下一行的上半截露在本页页尾（页界切字的老毛病）。
        return NotificationListener<UserScrollNotification>(
          onNotification: _onUserScroll,
          child: ClipRect(
            clipper: _EpubPageClipper(r),
            child: list,
          ),
        );
      },
    );
  }
}

/// page 模式视口裁剪：可视高度 = 当前落点到下一个**行边界页停**的距离。
///
/// 页尾因此留出一段空白（不足一行），页界不会落在任何字形中间；拖拽中
/// （[EpubRenderer.pageContentHeight] 返回视口高）不裁剪，保持连续内容
/// 的观感。
class _EpubPageClipper extends CustomClipper<Rect> {
  const _EpubPageClipper(this.renderer);

  final EpubRenderer renderer;

  @override
  Rect getClip(Size size) {
    final height = renderer.pageContentHeight(size.height);
    return Rect.fromLTWH(0, 0, size.width, height);
  }

  @override
  bool shouldReclip(_EpubPageClipper oldClipper) => true;
}

/// page 模式物理：按**页起点**吸附（页界不切字；插图独占一页）。
///
/// 与 Flutter 的 [PageScrollPhysics] 同构（按速度方向翻页 / 无速度时
/// 就近吸附），差别只在吸附单位：不是视口高的整数倍，而是内容里的页起点
/// （见 [EpubPageStructure]），故页界永远落在行与行之间，且插图整页。
///
/// 公开类名：测试需要断言 page 模式用的是本物理（而非视口高吸附）。
class EpubPageScrollPhysics extends ScrollPhysics {
  const EpubPageScrollPhysics({required this.renderer, super.parent});

  final EpubRenderer renderer;

  @override
  EpubPageScrollPhysics applyTo(ScrollPhysics? ancestor) => EpubPageScrollPhysics(
    renderer: renderer,
    parent: buildParent(ancestor),
  );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // 已到文档端头且不打算回程：交给父级（回弹到边界）。
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _targetPixels(position, tolerance, velocity);
    if (target != position.pixels) {
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        target,
        velocity,
        tolerance: tolerance,
      );
    }
    return null;
  }

  /// 吸附落点：有速度 → 翻到相邻页起点；无速度 → 就近页起点。
  ///
  /// 布局阶段不能测量渲染树，故读页结构里**已累积**的页停候选
  /// （[_EpubRenderer._pages]）——候选表跨滚动累积，滚到哪都能吸到。
  ///
  /// 关键：翻页动作（`jumpTo`）末尾会触发一次 `goBallistic(0)`，若无速度
  /// 吸附就会把页面**再挪一次**（按一次键翻两页）。故无速度时吸附到「
  /// 就近页起点」——而翻页落点本身就是页起点，距离 0 → 不产生二次位移。
  double _targetPixels(
    ScrollMetrics position,
    Tolerance tolerance,
    double velocity,
  ) {
    final double? stop;
    if (velocity < -tolerance.velocity) {
      stop = renderer._pages.peekPrevPageStart(position.pixels);
    } else if (velocity > tolerance.velocity) {
      stop = renderer._pages.peekNextPageStart(position.pixels);
    } else {
      stop = renderer._pages.nearestPageStart(position.pixels);
    }
    final double target =
        stop ??
        position.pixels +
            (velocity >= 0
                ? position.viewportDimension
                : -position.viewportDimension);
    return target.clamp(position.minScrollExtent, position.maxScrollExtent);
  }

  @override
  bool get allowImplicitScrolling => false;
}
