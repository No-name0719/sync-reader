/// pdf 阅读渲染器（FR-205）：pdfrx 1.3.5 渲染 + 页码指示/跳转 + 进度上报 +
/// 进度恢复 + 主题适配。
///
/// pdfrx 1.3.5 实际 API（本机源码为准；`PdfView`/`PdfControllerPinch` 是
/// 1.0 时代 API，1.3.x 已移除）：
/// - 视图 `PdfViewer(documentRef, controller, params, initialPageNumber)`；
///   默认即为**连续画布**：全部页面纵向排布，拖拽/滚轮连续滚动，内置
///   捏合/双击缩放（无逐页吸附模式）。
/// - 控制器 `PdfViewerController`：`pageNumber`（1 起）、`pageCount`、
///   `goToPage/goToArea`、`visibleRect`、`layout.pageLayouts`。
/// - 文档经 [pdfrx.PdfDocumentRefDirect] 注入视图（`createRenderer` 时已
///   `PdfDocument.openFile` 打开，视图与控制器共享同一实例，无重复加载）。
///
/// yRatio 说明：取**当前视口顶部**相对目标页顶的纵向比例
/// （`visibleRect.top` 与 `layout.pageLayouts` 同处文档布局坐标系，精确）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart' as pdfrx;

import '../../../../core/app_logger.dart';
import '../../contract/book_file.dart';
import '../../contract/book_renderer.dart';
import '../../contract/progress_anchor.dart';
import '../../contract/reader_controller.dart';
import '../../contract/reader_settings.dart';
import '../../contract/toc_entry.dart';
import 'pdf_locator.dart';
import 'pdf_page_anchor.dart';
import 'pdf_view_widgets.dart';

/// 进度上报节流间隔（docs/03 §3.1：防抖 3s）。
const _progressThrottleInterval = Duration(seconds: 3);

/// 页内纵向比例小于该阈值时按"页顶"处理（restore/jump 的吸附容差）。
const _yRatioEpsilon = 0.01;

/// 待执行的跳转（视图未就绪时挂起，onViewerReady 后落地）。
typedef _PendingJump = ({int pageIndex, double yRatio});

/// pdf 渲染器：视图 + 控制器成对暴露给宿主（契约 [BookRenderer]）。
class PdfRenderer implements BookRenderer {
  PdfRenderer._({
    required pdfrx.PdfDocument document,
    required ReaderSettings settings,
    required ProgressAnchor initialAnchor,
  }) : controller = PdfReaderController(
         document: document,
         settings: settings,
         initialAnchor: initialAnchor,
       );

  /// 打开 pdf 文件并创建渲染会话。
  ///
  /// 文件损坏/加密口令失败等 [pdfrx.PdfDocument.openFile] 异常原样抛出，
  /// 由宿主（ReaderPage）统一展示"无法打开本书"；此处不做静默降级。
  static Future<PdfRenderer> open({
    required BookFile file,
    required ReaderSettings settings,
    required ProgressAnchor initialAnchor,
  }) async {
    final document = await pdfrx.PdfDocument.openFile(file.path);
    return PdfRenderer._(
      document: document,
      settings: settings,
      initialAnchor: initialAnchor,
    );
  }

  @override
  final PdfReaderController controller;

  /// 集成阶段入口：阅读设置变更时热更新（当前仅主题背景色对 pdf 生效；
  /// 字号/行距等排版设置与 pdf 版式无关，忽略）。
  void applySettings(ReaderSettings settings) =>
      controller.applySettings(settings);

  @override
  Widget buildView(BuildContext context) =>
      PdfReaderView(controller: controller);

  @override
  void dispose() => controller.dispose();
}

/// pdf 阅读控制器（契约 [ReaderController]）。
class PdfReaderController implements ReaderController {
  /// [document] 所有权转移至本控制器（[dispose] 时关闭）。
  PdfReaderController({
    required pdfrx.PdfDocument document,
    required ReaderSettings settings,
    required ProgressAnchor initialAnchor,
  }) : _document = document,
       _settings = ValueNotifier(settings),
       _restoreDecision = decideRestore(initialAnchor, document.pages.length) {
    _documentRef = pdfrx.PdfDocumentRefDirect(document, autoDispose: false);
    final decision = _restoreDecision;
    _currentPageIndex = decision.targetPageIndex;
    _currentYRatio = decision.yRatio;
    _pageIndexNotifier = ValueNotifier<int>(_currentPageIndex);
  }

  final _log = AppLogger();
  final pdfrx.PdfDocument _document;
  final ValueNotifier<ReaderSettings> _settings;
  late final pdfrx.PdfDocumentRefDirect _documentRef;
  late final ValueNotifier<int> _pageIndexNotifier;

  pdfrx.PdfViewerController? _viewer;
  _PendingJump? _pendingJump;
  PdfRestoreDecision _restoreDecision;
  var _restoreApplied = false;
  var _disposed = false;

  var _currentPageIndex = 0;
  var _currentYRatio = 0.0;
  Timer? _throttleTimer;

  /// 阅读设置（主题）的可监听源（视图据此重建 viewer 参数）。
  ValueListenable<ReaderSettings> get settingsListenable => _settings;

  /// 集成阶段入口：热更新阅读设置。
  void applySettings(ReaderSettings settings) {
    if (_disposed) return;
    _settings.value = settings;
  }

  /// pdf 文档引用（视图创建 [pdfrx.PdfViewer] 用）。
  pdfrx.PdfDocumentRef get documentRef => _documentRef;

  /// 总页数（退化文档可为 0）。
  int get pageCount => _pageCount;

  /// 当前页（0 起）的可监听源（页码指示用）。
  ValueListenable<int> get pageIndexListenable => _pageIndexNotifier;

  /// 视图打开时建议的起始页（1 起；有已保存进度时直达目标页避免首屏闪烁）。
  int get initialPageNumber {
    final decision = _restoreDecision;
    if (decision.mode == ReaderRestoreMode.noProgress) return 1;
    return decision.targetPageIndex.clamp(0, _pageCount - 1) + 1;
  }

  /// 总页数。
  int get _pageCount {
    if (_disposed) return 0;
    return _document.pages.length;
  }

  // ---- 视图生命周期挂接（由 PdfReaderView 调用） ----

  /// 视图就绪：挂接缩放/平移监听。
  void attachViewer(pdfrx.PdfViewerController viewer) {
    _viewer = viewer;
    viewer.addListener(_onViewerMatrixChanged);
  }

  /// 视图文档加载完成：落地挂起的 restore/跳转。
  void handleViewerReady() {
    if (_restoreApplied) {
      _flushPendingJump();
      return;
    }
    _restoreApplied = true;
    final decision = _restoreDecision;
    if (decision.mode == ReaderRestoreMode.noProgress) {
      _flushPendingJump();
      return;
    }
    // exact / degraded 都需要定位到目标页（降级=percent 最近页，docs/05 §3.3）。
    unawaited(_jumpToPageIndex(decision.targetPageIndex, decision.yRatio));
  }

  /// 视图销毁：解除监听。
  void detachViewer(pdfrx.PdfViewerController viewer) {
    viewer.removeListener(_onViewerMatrixChanged);
    if (identical(_viewer, viewer)) _viewer = null;
  }

  // ---- 契约实现（ReaderController） ----

  @override
  ReaderProgressCallback? onProgressChanged;

  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async {
    if (_disposed) {
      return ReaderRestoreResult(
        mode: ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );
    }
    final decision = decideRestore(saved, _pageCount);
    _restoreDecision = decision;
    _restoreApplied = false;
    _currentPageIndex = decision.targetPageIndex;
    _currentYRatio = decision.yRatio;
    _pageIndexNotifier.value = _currentPageIndex;
    if (decision.mode != ReaderRestoreMode.noProgress) {
      _pendingJump = (
        pageIndex: decision.targetPageIndex,
        yRatio: decision.yRatio,
      );
      handleViewerReady(); // 视图已就绪则立即跳，否则保持挂起
    }
    return ReaderRestoreResult(mode: decision.mode, applied: decision.applied);
  }

  @override
  ProgressAnchor get currentLocator => ProgressAnchor(
    locatorJson: encodePdfLocator(_currentPageIndex, _currentYRatio),
    percent: percent,
  );

  @override
  double get percent => percentForPage(_currentPageIndex, _pageCount);

  @override
  Future<void> jumpTo(TocEntry entry) async {
    final anchor = entry.anchor;
    if (anchor is! PdfPageAnchor) {
      // 防御：页数指纹等非页锚点（pagesFingerprintEntry）不可跳转。
      _log.warn('pdf jumpTo：非页锚点，忽略（${entry.anchor.runtimeType}）');
      return;
    }
    await _jumpToPageIndex(anchor.pageIndex, anchor.yRatio);
  }

  /// 页码跳转（0 起页码；页码指示对话框与目录跳转共用）。
  Future<void> jumpToPageIndex(int pageIndex) => _jumpToPageIndex(pageIndex, 0);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    final viewer = _viewer;
    if (viewer != null) detachViewer(viewer);
    _pageIndexNotifier.dispose();
    _settings.dispose();
    unawaited(_document.dispose());
  }

  // ---- 内部：跳转 / 进度采集 ----

  Future<void> _jumpToPageIndex(int pageIndex, double yRatio) async {
    if (_disposed) return;
    final pageCount = _pageCount;
    final index = pageCount > 0 ? pageIndex.clamp(0, pageCount - 1) : 0;
    _currentPageIndex = index;
    _currentYRatio = yRatio.clamp(0.0, 1.0);
    _pageIndexNotifier.value = index;

    final viewer = _viewer;
    if (viewer == null || !viewer.isReady) {
      _pendingJump = (pageIndex: index, yRatio: _currentYRatio);
      return;
    }
    _pendingJump = null;
    try {
      if (_currentYRatio > _yRatioEpsilon) {
        // 页内定位：把目标页 yRatio 处对齐到视口顶部（文档布局坐标系）。
        final layouts = viewer.layout.pageLayouts;
        if (index < layouts.length) {
          final rect = layouts[index];
          await viewer.goToArea(
            rect: Rect.fromLTWH(
              rect.left,
              rect.top + _currentYRatio * rect.height,
              rect.width,
              1,
            ),
            anchor: pdfrx.PdfPageAnchor.top,
          );
          return;
        }
      }
      await viewer.goToPage(pageNumber: index + 1);
    } catch (e, s) {
      _log.warn('pdf 页码跳转失败：$e');
      _log.error('pdf 跳转异常详情', e, s);
    }
  }

  void _flushPendingJump() {
    final pending = _pendingJump;
    if (pending != null) {
      _pendingJump = null;
      unawaited(_jumpToPageIndex(pending.pageIndex, pending.yRatio));
    }
  }

  /// 平移/缩放矩阵变化：更新当前页与 yRatio 并节流上报。
  void _onViewerMatrixChanged() {
    if (_disposed) return;
    final viewer = _viewer;
    if (viewer == null || !viewer.isReady) return;
    var pageChanged = false;
    final pageNumber = _safePageNumber(viewer);
    if (pageNumber != null && pageNumber != _currentPageIndex + 1) {
      _currentPageIndex = pageNumber - 1;
      pageChanged = true;
    }
    _currentYRatio = _computeYRatio(viewer);
    _pageIndexNotifier.value = _currentPageIndex;
    _notifyProgressThrottled(pageChanged);
  }

  /// pdfrx onPageChanged（1 起页码，可能为 null）：矩阵监听的兜底/补充。
  void handleViewerPageChanged(int? pageNumber) {
    if (_disposed || pageNumber == null || pageNumber < 1) return;
    if (pageNumber == _currentPageIndex + 1) return;
    _currentPageIndex = pageNumber - 1;
    _pageIndexNotifier.value = _currentPageIndex;
    _notifyProgressThrottled(true);
  }

  int? _safePageNumber(pdfrx.PdfViewerController viewer) {
    try {
      return viewer.pageNumber;
    } catch (_) {
      return null; // 未就绪/未布局
    }
  }

  /// 当前视口顶部在目标页内的纵向比例 0.0–1.0。
  ///
  /// `visibleRect` 与 `layout.pageLayouts` 同为文档布局坐标，可精确计算；
  /// 视图未就绪（layout 未建）时 pdfrx 会抛错 → 按页顶 0.0 处理。
  double _computeYRatio(pdfrx.PdfViewerController viewer) {
    try {
      final pageNumber = viewer.pageNumber;
      if (pageNumber == null || pageNumber < 1) return 0;
      final layouts = viewer.layout.pageLayouts;
      if (pageNumber > layouts.length) return 0;
      final pageRect = layouts[pageNumber - 1];
      if (pageRect.height <= 0) return 0;
      final ratio = (viewer.visibleRect.top - pageRect.top) / pageRect.height;
      return ratio.clamp(0.0, 1.0);
    } catch (_) {
      return 0;
    }
  }

  /// 节流上报（docs/03 §3.1 防抖 3s）：
  /// - 翻页（页码变化）立即上报——页级进度是恢复的主坐标，宁多勿丢；
  /// - 仅 yRatio 变化（同页滚动/缩放）按 3s 尾沿合并上报。
  void _notifyProgressThrottled(bool pageChanged) {
    if (_disposed) return;
    final callback = onProgressChanged;
    if (callback == null) return;
    if (pageChanged) {
      _flushProgress(callback);
      return;
    }
    if (_throttleTimer != null) return; // 已有待触发任务，合并
    _throttleTimer = Timer(_progressThrottleInterval, () {
      _throttleTimer = null;
      if (_disposed) return;
      final cb = onProgressChanged;
      if (cb != null) _flushProgress(cb);
    });
  }

  void _flushProgress(ReaderProgressCallback callback) {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    callback(currentLocator, percent);
  }
}

/// pdf 阅读视图：pdfrx 画布 + 悬浮页码指示（点击弹页码跳转对话框）。
class PdfReaderView extends StatefulWidget {
  const PdfReaderView({super.key, required this.controller});

  /// 所属渲染器的控制器。
  final PdfReaderController controller;

  @override
  State<PdfReaderView> createState() => _PdfReaderViewState();
}

class _PdfReaderViewState extends State<PdfReaderView> {
  final _viewerController = pdfrx.PdfViewerController();

  @override
  void initState() {
    super.initState();
    widget.controller.attachViewer(_viewerController);
  }

  @override
  void didUpdateWidget(covariant PdfReaderView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detachViewer(_viewerController);
      widget.controller.attachViewer(_viewerController);
    }
  }

  @override
  void dispose() {
    widget.controller.detachViewer(_viewerController);
    super.dispose();
  }

  Future<void> _showJumpDialog() async {
    await showPdfPageJumpDialog(
      context,
      pageCount: widget.controller.pageCount,
      onJump: widget.controller.jumpToPageIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReaderSettings>(
      valueListenable: widget.controller.settingsListenable,
      builder: (context, settings, _) {
        final params = pdfrx.PdfViewerParams(
          backgroundColor: pdfViewerBackgroundColor(settings.theme),
          onPageChanged: widget.controller.handleViewerPageChanged,
          onViewerReady: (_, _) => widget.controller.handleViewerReady(),
        );
        return Stack(
          children: [
            pdfrx.PdfViewer(
              widget.controller.documentRef,
              controller: _viewerController,
              params: params,
              initialPageNumber: widget.controller.initialPageNumber,
            ),
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: PdfPageIndicator(
                  pageIndexListenable: widget.controller.pageIndexListenable,
                  pageCount: widget.controller.pageCount,
                  onTap: _showJumpDialog,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
