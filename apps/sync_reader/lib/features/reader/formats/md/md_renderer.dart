/// md 渲染器（FR-204）：分块渲染 + 滚动进度定位 + 三分支恢复 + 目录跳转。
///
/// 渲染策略：`ListView.builder` 按块懒构建，每块一个 [MarkdownBody]
/// （flutter_markdown_plus，GFM 扩展集），块容器持 GlobalKey 作为锚点——
/// 滚动时找视口顶部可见块上报 locator；restore/jumpTo 用
/// `Scrollable.ensureVisible` 滚到目标块（未构建时按字符比例估算偏移跨帧重试）。
///
/// 进度管线（docs/05 §3.3 type=md + 契约约定）：
/// - percent = 可见块 sourceStart / 全文字符数；
/// - locator = `{"type":"md","headingIndex":最近标题序号,"blockIndex":可见块下标,"charOffset":块首偏移}`；
/// - 滚动上报经 3s 节流（leading 立即 + 尾随补偿，docs/03 §3.1）；
///   [MdReaderController.currentLocator]/[MdReaderController.percent] 始终实时，
///   宿主退出/切后台时主动读取兜底落库（FR-207）。
///
/// 已知边界（报告事项）：pageMode == page 暂按 scroll 处理（FR-204 未强制分页）；
/// md 内相对路径图片渲染占位；链接可渲染但点击行为待集成阶段接入。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_controller.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import 'md_block_parser.dart';
import 'md_locator.dart';
import 'md_style.dart';

/// md 阅读控制器：[ReaderController] 的薄壳，逻辑在 [MdRenderer]。
class MdReaderController extends ReaderController {
  MdReaderController._(this._renderer);

  final MdRenderer _renderer;

  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) =>
      _renderer.restore(saved);

  @override
  ProgressAnchor get currentLocator => _renderer.currentAnchor;

  @override
  double get percent => _renderer.currentPercent;

  @override
  Future<void> jumpTo(TocEntry entry) => _renderer.jumpToEntry(entry);

  @override
  void dispose() => _renderer.dispose();
}

/// md 渲染器（scroll 模式）。
class MdRenderer extends BookRenderer {
  /// [blocks] 为块解析结果；[documentLength] 是全文源文本字符数（percent 分母）；
  /// [initialAnchor] 为已保存进度（宿主随后应调用 [controller.restore] 完成
  /// 定位滚动；创建时仅同步 currentLocator，不滚动）。
  MdRenderer({
    required List<MdBlock> blocks,
    required this._documentLength,
    this._settings = ReaderSettings.defaults,
    ProgressAnchor initialAnchor = ProgressAnchor.empty,
  }) : _blocks = List.unmodifiable(blocks) {
    _controller = MdReaderController._(this);
    _keys = List<GlobalKey>.generate(_blocks.length, (_) => GlobalKey());
    _styleSheet = buildMdStyleSheet(_settings);
    _throttle = _ProgressThrottle(
      interval: const Duration(seconds: 3),
      onFire: _fireProgress,
    );
    _initFromAnchor(initialAnchor);
    _scrollController.addListener(_handleScroll);
  }

  final List<MdBlock> _blocks;
  final int _documentLength;
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _viewportKey = GlobalKey();

  ReaderSettings _settings;
  late final MdReaderController _controller;
  late final List<GlobalKey> _keys;
  late final _ProgressThrottle _throttle;
  late MarkdownStyleSheet _styleSheet;
  _MdReaderViewState? _view;
  bool _disposed = false;

  String _locatorJson = MdLocator.encode(
    headingIndex: 0,
    blockIndex: 0,
    charOffset: 0,
  );
  double _currentPercent = 0;
  int _lastComputedIndex = -1;
  int _settledIndex = -1;
  bool _recheckScheduled = false;

  // ---- BookRenderer 契约 ----

  @override
  MdReaderController get controller => _controller;

  @override
  Widget buildView(BuildContext context) => _MdReaderView(renderer: this);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _throttle.dispose();
    _view = null;
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
  }

  // ---- 公开 API（集成阶段使用） ----

  /// 应用新排版设置（FR-206）：即时重建样式并刷新视图，滚动位置保持不变。
  void applySettings(ReaderSettings settings) {
    if (_disposed || settings == _settings) return;
    _settings = settings;
    _styleSheet = buildMdStyleSheet(settings);
    _view?._refresh();
  }

  /// 当前阅读设置。
  ReaderSettings get settings => _settings;

  /// 块列表（只读视图）。
  List<MdBlock> get blocks => _blocks;

  /// 全文滚动控制器（视图持有；诊断/测试用）。
  ScrollController get scrollController => _scrollController;

  /// 视口锚点 Key（诊断/测试用）。
  GlobalKey get viewportKey => _viewportKey;

  /// 当前逻辑位置（locator JSON + percent，始终实时）。
  ProgressAnchor get currentAnchor =>
      ProgressAnchor(locatorJson: _locatorJson, percent: _currentPercent);

  /// 当前全书阅读比例 0.0–1.0。
  double get currentPercent => _currentPercent;

  /// 跳转到目录条目（MdHeadingAnchor → 滚到对应标题块）。
  Future<void> jumpToEntry(TocEntry entry) async {
    if (_disposed) return;
    final anchor = entry.anchor;
    final headingOrdinal = anchor is MdHeadingAnchor
        ? anchor.headingIndex
        : MdHeadingAnchor.tryParse(anchor.toString())?.headingIndex;
    if (headingOrdinal == null) return;
    final blockIndex = MdPositionMath.blockIndexForHeading(
      _blocks,
      headingOrdinal,
    );
    if (blockIndex < 0) return;
    await _scrollToBlock(blockIndex);
  }

  /// 恢复进度（docs/05 §3.3 三分支）：
  /// - 无进度 → noProgress，留在开头；
  /// - locator 有效（type=md 且 blockIndex 在界内）→ exact，滚到该块；
  /// - locator 解析失败/越界 → degradedToPercent，percent 换算最近块；
  ///   applied 的 locator 为空对象、percent 保持不变（契约约定）。
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async {
    if (_disposed) {
      return const ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    }
    if (!saved.hasProgress || _blocks.isEmpty) {
      _locatorJson = MdLocator.encode(
        headingIndex: 0,
        blockIndex: 0,
        charOffset: 0,
      );
      _currentPercent = 0;
      return const ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    }

    final data = MdLocator.tryDecode(saved.locatorJson);
    if (data != null && data.blockIndex < _blocks.length) {
      _locatorJson = MdLocator.encode(
        headingIndex: data.headingIndex,
        blockIndex: data.blockIndex,
        charOffset: data.charOffset,
      );
      _currentPercent = saved.percent;
      // applied 先于定位滚动取值：percent 保持保存值，不被实际落点覆盖。
      final applied = currentAnchor;
      await _scrollToBlock(data.blockIndex);
      return ReaderRestoreResult(
        mode: ReaderRestoreMode.exact,
        applied: applied,
      );
    }

    final target = MdPositionMath.blockIndexForPercent(
      _blocks,
      _documentLength,
      saved.percent,
    );
    _locatorJson = MdLocator.encode(
      headingIndex: MdPositionMath.headingIndexUpTo(_blocks, target),
      blockIndex: target,
      charOffset: _blocks[target].sourceStart,
    );
    _currentPercent = saved.percent;
    await _scrollToBlock(target);
    // 契约约定：降级时 percent 保持不变、locator 为空对象。
    return ReaderRestoreResult(
      mode: ReaderRestoreMode.degradedToPercent,
      applied: ProgressAnchor(locatorJson: '{}', percent: saved.percent),
    );
  }

  // ---- 视图构建 ----

  /// 构建单块视图（ [_MdReaderView] 的 itemBuilder 委托）。
  Widget buildBlock(BuildContext context, int index) {
    final block = _blocks[index];
    final content = MarkdownBody(
      data: block.content,
      styleSheet: _styleSheet,
      imageBuilder: (uri, title, alt) => _buildImage(uri, alt),
      softLineBreak: false,
    );
    // 标题块上方留章节分隔感；块间基础间距交给 MarkdownStyleSheet.blockSpacing
    // 与块自身的 bottom padding。
    final topGap = block.type == MdBlockType.heading && index > 0
        ? _settings.fontSize
        : 0.0;
    return KeyedSubtree(
      key: _keys[index],
      child: Padding(
        padding: EdgeInsets.only(
          top: topGap,
          bottom: _settings.fontSize * 0.35,
        ),
        child: content,
      ),
    );
  }

  Widget _buildImage(Uri uri, String? alt) {
    final placeholder = _imagePlaceholder(alt, mdPaletteFor(_settings.theme));
    switch (uri.scheme) {
      case 'http' || 'https':
        return Image.network(
          uri.toString(),
          errorBuilder: (_, _, _) => placeholder,
        );
      case 'data':
        final data = uri.data;
        if (data == null) return placeholder;
        return Image.memory(
          data.contentAsBytes(),
          errorBuilder: (_, _, _) => placeholder,
        );
      default:
        // 相对路径/本地文件图片暂不支持（M1 范围外），渲染占位。
        return placeholder;
    }
  }

  Widget _imagePlaceholder(String? alt, MdPalette palette) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: palette.codeBackground,
      border: Border.all(color: palette.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.image_not_supported_outlined,
          color: palette.secondary,
          size: 28,
        ),
        if (alt != null && alt.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            alt,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: palette.secondary),
          ),
        ],
      ],
    ),
  );

  // ---- 进度定位与恢复 ----

  void _initFromAnchor(ProgressAnchor anchor) {
    _currentPercent = anchor.hasProgress ? anchor.percent : 0;
    final data = anchor.hasProgress
        ? MdLocator.tryDecode(anchor.locatorJson)
        : null;
    if (data != null && data.blockIndex < _blocks.length) {
      _locatorJson = MdLocator.encode(
        headingIndex: data.headingIndex,
        blockIndex: data.blockIndex,
        charOffset: data.charOffset,
      );
    } else {
      _locatorJson = MdLocator.encode(
        headingIndex: 0,
        blockIndex: 0,
        charOffset: 0,
      );
    }
  }

  /// 滚到指定块（块顶对齐视口顶）。对齐采用"实测位移差"逐步收敛：
  /// 每帧重测目标块与视口的全局坐标差并 jumpTo 抵消（不受 ListView 前导
  /// padding 等布局细节影响）；块尚未构建时先按字符比例估算偏移跳转、
  /// 等下一帧重试（restore 在 buildView 之前被宿主调用的场景即靠此收敛）。
  /// 已滚动到视口上下边界且目标仍偏在一侧时，视为已到文档端头，就地收敛。
  Future<void> _scrollToBlock(int index) async {
    if (_disposed || index < 0 || index >= _blocks.length) return;
    for (var attempt = 0; attempt < 12; attempt++) {
      if (_disposed) return;
      final delta = _blockTopDeltaFromViewportTop(index);
      if (delta != null && _scrollController.hasClients) {
        if (delta.abs() <= 0.5) {
          _updateFromViewport(); // 定位完成：用最终布局刷新当前锚点。
          return;
        }
        final max = _scrollController.position.maxScrollExtent;
        final offset = _scrollController.offset;
        final atTop = offset <= 0.5;
        final atBottom = offset >= max - 0.5;
        if ((delta < 0 && atTop) || (delta > 0 && atBottom)) {
          _updateFromViewport();
          return;
        }
        _scrollController.jumpTo((offset + delta).clamp(0.0, max));
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }
      // 块未构建/未布局：按字符比例估算偏移先跳，等下一帧重试。
      if (_scrollController.hasClients) {
        final max = _scrollController.position.maxScrollExtent;
        final estimate = (_documentLength <= 0 || max <= 0)
            ? 0.0
            : (_blocks[index].sourceStart / _documentLength * max).clamp(
                0.0,
                max,
              );
        _scrollController.jumpTo(estimate);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  /// 目标块顶相对视口顶的位移（逻辑像素，向下为正）；块未构建/未布局返回 null。
  double? _blockTopDeltaFromViewportTop(int index) {
    final box = _keys[index].currentContext?.findRenderObject();
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    return box.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
  }

  /// 滚动监听：更新实时 currentLocator/percent，并经节流上报宿主。
  /// 程序化滚动（jumpTo/restore）只有一次位置变化、且可能早于布局生效，
  /// 故再排一帧复测自校正（布局收敛后自动停止）。
  void _handleScroll() {
    if (_disposed) return;
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

  /// 用当前视口测量刷新 currentLocator/percent；返回可见块下标（测不到为 null）。
  int? _updateFromViewport() {
    if (_disposed) return null;
    final index = _topVisibleBlockIndex();
    if (index == null || index == _lastComputedIndex) return index;
    _lastComputedIndex = index;
    _locatorJson = MdLocator.encode(
      headingIndex: MdPositionMath.headingIndexUpTo(_blocks, index),
      blockIndex: index,
      charOffset: _blocks[index].sourceStart,
    );
    _currentPercent = _documentLength <= 0
        ? 0
        : (_blocks[index].sourceStart / _documentLength).clamp(0.0, 1.0);
    _throttle.report(currentAnchor, _currentPercent);
    return index;
  }

  /// 视口顶部可见块下标：第一个与视口相交的块（跨视口顶的块优先，
  /// 即"正在读的块"）。块未构建（ListView 懒加载窗口外）时跳过。
  int? _topVisibleBlockIndex() {
    if (_blocks.isEmpty) return null;
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return null;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    for (var i = 0; i < _keys.length; i++) {
      final box = _keys[i].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom > viewportTop + 1 && top < viewportBottom - 1) return i;
    }
    return null;
  }

  void _fireProgress(ProgressAnchor anchor, double percent) {
    _controller.onProgressChanged?.call(anchor, percent);
  }

  void _attachView(_MdReaderViewState view) => _view = view;

  void _detachView(_MdReaderViewState view) {
    if (identical(_view, view)) _view = null;
  }
}

/// 进度节流器：窗口期（防抖 3s，docs/03 §3.1）内的首次立即上报（leading），
/// 之后的更新暂存，窗口结束时补发最新一次（尾随），保证停下后位置最终一致。
/// 无后续更新时链条自然终止，不留悬挂 Timer。
class _ProgressThrottle {
  _ProgressThrottle({required this.interval, required this.onFire});

  final Duration interval;
  final void Function(ProgressAnchor anchor, double percent) onFire;

  Timer? _window;
  ProgressAnchor? _pendingAnchor;
  double _pendingPercent = 0;

  void report(ProgressAnchor anchor, double percent) {
    if (_window != null) {
      _pendingAnchor = anchor;
      _pendingPercent = percent;
      return;
    }
    onFire(anchor, percent);
    _window = Timer(interval, _onWindowEnd);
  }

  void _onWindowEnd() {
    _window = null;
    final pending = _pendingAnchor;
    if (pending == null) return;
    _pendingAnchor = null;
    report(pending, _pendingPercent);
  }

  void dispose() {
    _window?.cancel();
    _window = null;
    _pendingAnchor = null;
  }
}

/// md 阅读视图：渲染器设置的响应壳（applySettings → setState 重建）。
class _MdReaderView extends StatefulWidget {
  const _MdReaderView({required this.renderer});

  final MdRenderer renderer;

  @override
  State<_MdReaderView> createState() => _MdReaderViewState();
}

class _MdReaderViewState extends State<_MdReaderView> {
  @override
  void initState() {
    super.initState();
    widget.renderer._attachView(this);
  }

  @override
  void didUpdateWidget(covariant _MdReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      oldWidget.renderer._detachView(this);
      widget.renderer._attachView(this);
    }
  }

  @override
  void dispose() {
    widget.renderer._detachView(this);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final renderer = widget.renderer;
    final palette = mdPaletteFor(renderer.settings.theme);
    final blocks = renderer.blocks;
    return Container(
      key: renderer.viewportKey,
      color: palette.background,
      child: blocks.isEmpty
          ? Center(
              child: Text('（空文档）', style: TextStyle(color: palette.secondary)),
            )
          : ListView.builder(
              controller: renderer.scrollController,
              padding: EdgeInsets.all(renderer.settings.pageMargin),
              itemCount: blocks.length,
              itemBuilder: (context, index) =>
                  renderer.buildBlock(context, index),
            ),
    );
  }
}
