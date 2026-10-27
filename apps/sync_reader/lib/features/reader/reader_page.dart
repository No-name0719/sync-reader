/// 阅读页（FR-201/206/207/208 基础版 + FR-108 目录抽屉）。
///
/// 完整打开链路：取 Book 行（无 localPath → 占位提示页；书不存在 → 自动
/// pop 返回）→ handler.parseMetadata（取 toc，与渲染器创建并行）→
/// ProgressDao.getByBookId → ProgressAnchor.fromRaw → createRenderer →
/// controller.restore → buildView。渲染器创建异常 → 错误页（信息 + 重试）。
///
/// 进度管线（FR-207，docs/03 §3.1）：渲染器节流后回调 onProgressChanged →
/// 宿主防抖 3s（trailing）落库 progress（dirty=true）+ 刷新 lastReadAt；
/// 切后台（paused）与退出阅读页立即落库（取消挂起的防抖）。
///
/// 阅读时长（FR-208 基础版）：页面就绪且 app resumed 时每秒累计；
/// 切后台/退出时 `updateProgressInfo(addTotalSeconds)` 落库并刷新 lastReadAt。
///
/// 设置热应用（FR-206）：监听 ReaderSettingsRepository.changes，经渲染器的
/// `applySettings` 约定扩展方法下发（契约之外的公开约定，三个真实渲染器均实现）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../app/providers.dart';
import '../../core/app_logger.dart';
import '../../data/db/app_database.dart' show Book;
import '../../data/db/daos/books_dao.dart';
import '../../data/db/daos/progress_dao.dart';
import '../../features/sync/sync_facade.dart';
import '../../features/sync/sync_triggers.dart';
import 'contract/book_file.dart';
import 'contract/book_renderer.dart';
import 'contract/progress_anchor.dart';
import 'contract/reader_settings.dart';
import 'contract/reader_settings_repository.dart';
import 'contract/toc_entry.dart';
import 'settings/settings_panel.dart';

/// 进度落库防抖窗口（docs/03 §3.1：翻页/滚动后 3s）。
const Duration progressDebounceInterval = Duration(seconds: 3);

/// 阅读时长累计步长（每秒一跳，切后台/退出结算）。
const Duration readingClockInterval = Duration(seconds: 1);

/// 目录条目每级缩进量。
const double _tocIndentPerLevel = 16;

/// 阅读页状态的打开结果。
sealed class _PageState {
  const _PageState();
}

/// 打开中。
final class _OpeningState extends _PageState {
  const _OpeningState();
}

/// 书不存在（自动 pop 返回）。
final class _MissingBookState extends _PageState {
  const _MissingBookState();
}

/// 占位书（云端有、本地无正文）。
final class _PlaceholderState extends _PageState {
  const _PlaceholderState();
}

/// 打开失败（错误信息 + 重试）。
final class _ErrorState extends _PageState {
  const _ErrorState(this.error);

  final Object error;
}

/// 打开成功。
final class _ReadyState extends _PageState {
  const _ReadyState({required this.session, required this.toc});

  final _ReaderSession session;
  final List<TocEntry> toc;
}

/// 阅读会话：一页打开期间持有的书籍信息与渲染器。
class _ReaderSession {
  _ReaderSession({required this.book, required this.renderer});

  final Book book;
  final BookRenderer renderer;
}

/// 阅读页（`/reader/:bookId`）。
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.bookId});

  /// 目标书籍 ULID。
  final String bookId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage>
    with WidgetsBindingObserver {
  final _log = AppLogger();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  // DAO 与设置仓库在 initState 取好引用（dispose 中不允许再用 ref）。
  late final ProgressDao _progressDao;
  late final BooksDao _booksDao;
  late final ReaderSettingsRepository _settingsRepo;

  /// M2 同步触发器（进度防抖推送的挂点；取引用避免 dispose 期再用 ref）。
  late final SyncTriggers _syncTriggers;
  StreamSubscription<ReaderSettings>? _settingsSub;

  _PageState _state = const _OpeningState();

  /// 页面是否已进入 dispose（dispose 期的兜底落库不再触发同步防抖）。
  bool _disposed = false;

  // —— 进度管线（FR-207）——
  Timer? _progressDebounce;
  bool _progressDirty = false;
  ProgressAnchor? _pendingAnchor;
  double _pendingPercent = 0;

  // —— 阅读时长（FR-208 基础版）——
  Timer? _readingClock;
  int _readingSeconds = 0;

  /// 当前打开成功的会话（防抖/退出结算用）。
  _ReaderSession? get _session => switch (_state) {
    final _ReadyState s => s.session,
    _ => null,
  };

  /// app 生命周期是否处于前台（null 视为 resumed：桌面启动早期即在前台）。
  bool get _isAppResumed {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _progressDao = ref.read(progressDaoProvider);
    _booksDao = ref.read(booksDaoProvider);
    _settingsRepo = ref.read(readerSettingsRepositoryProvider);
    _syncTriggers = ref.read(syncTriggersProvider);
    // 设置热应用（FR-206）：仓库广播 → 当前渲染器 applySettings。
    _settingsSub = _settingsRepo.changes.listen(_applySettings);
    _open();
  }

  @override
  void dispose() {
    _disposed = true;
    // 先同步取走最终进度，再销毁渲染器；DB 写入异步自然完成（FR-207 退出兜底）。
    _progressDebounce?.cancel();
    _progressDebounce = null;
    _readingClock?.cancel();
    _readingClock = null;
    // 同步防抖与页面同生命周期：先取消挂起的推送防抖（下面退出推送走
    // flushProgress 立即路径），保证卸载后无悬挂 Timer。
    _syncTriggers.cancelProgressDebounce(widget.bookId);
    final session = _session;
    if (session != null && _progressDirty) {
      _progressDirty = false;
      unawaited(
        _writeProgress(
          session.renderer.controller.currentLocator,
          session.renderer.controller.percent,
        ),
      );
      // 退出阅读页：立即推送该书待传进度（docs/04 §3 触发时机 3）。
      unawaited(_syncTriggers.flushProgress(widget.bookId));
    }
    unawaited(_flushReadingTime());
    session?.renderer.dispose();
    unawaited(_updateWindowTitle('SyncReader'));
    _settingsSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_session != null) _startReadingClock();
      return;
    }
    // 切后台/不可见：停计时并立即结算（FR-207/208）。
    _readingClock?.cancel();
    _readingClock = null;
    unawaited(_flushReadingTime());
    unawaited(_flushPendingProgress());
  }

  // ============================================================================
  // 打开链路（FR-201）
  // ============================================================================

  Future<void> _open() async {
    if (!mounted) return;
    setState(() => _state = const _OpeningState());
    Book? book;
    try {
      book = await _booksDao.getById(widget.bookId);
    } catch (e, s) {
      _log.error('读取书籍失败', e, s);
      if (mounted) setState(() => _state = _ErrorState(e));
      return;
    }
    if (!mounted) return;
    if (book == null) {
      setState(() => _state = const _MissingBookState());
      // 书不存在：下一帧自动返回书库。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }
    final localPath = book.localPath;
    if (localPath == null || localPath.isEmpty) {
      setState(() => _state = const _PlaceholderState());
      return;
    }

    BookRenderer? renderer;
    try {
      final registry = ref.read(formatRegistryProvider);
      final handler =
          registry.byFormatId(book.format) ??
          registry.byExtension(
            p.extension(book.fileName).replaceFirst('.', ''),
          );
      if (handler == null) {
        throw StateError('未注册的书籍格式：${book.format}');
      }

      // 直接用书行构造（导入时已校验文件存在、size 已入库；免 stat 系统调用）。
      final file = BookFile(
        path: localPath,
        fileName: book.fileName,
        sizeBytes: book.sizeBytes,
      );
      final settings = await _settingsRepo.load();

      // toc 解析与渲染器创建并行：toc 失败不影响打开（目录按钮降级隐藏）。
      final tocFuture = handler
          .parseMetadata(file)
          .then<List<TocEntry>>((parsed) => parsed.toc)
          .catchError((Object _) => <TocEntry>[]);

      final savedProgress = await _progressDao.getByBookId(widget.bookId);
      final anchor = savedProgress == null
          ? ProgressAnchor.empty
          : ProgressAnchor.fromRaw(
              savedProgress.locatorJson,
              savedProgress.percent,
            );

      renderer = await handler.createRenderer(file, settings, anchor);
      try {
        await renderer.controller.restore(anchor);
      } catch (e, s) {
        // 恢复失败降级为从头阅读，不阻塞打开。
        _log.warn('进度恢复失败，从头开始');
        _log.error('恢复异常详情', e, s);
      }
      renderer.controller.onProgressChanged = _onProgressChanged;

      final toc = await tocFuture;
      if (!mounted) {
        renderer.dispose();
        return;
      }
      setState(() {
        _state = _ReadyState(
          session: _ReaderSession(book: book!, renderer: renderer!),
          toc: toc,
        );
      });
      unawaited(_updateWindowTitle(book.title));
      if (_isAppResumed) _startReadingClock();
    } catch (e, s) {
      renderer?.dispose();
      _log.error('打开书籍失败', e, s);
      if (mounted) setState(() => _state = _ErrorState(e));
    }
  }

  /// Windows 桌面：窗口标题同步为书名（插件未就绪/其他平台静默忽略）。
  Future<void> _updateWindowTitle(String title) async {
    if (!Platform.isWindows) return;
    try {
      await windowManager.setTitle(title);
    } catch (_) {
      // 测试环境/插件未初始化：静默。
    }
  }

  // ============================================================================
  // 进度管线（FR-207）
  // ============================================================================

  /// 渲染器节流上报的进度：记下最新值并挂 3s 防抖（trailing）。
  void _onProgressChanged(ProgressAnchor locator, double percent) {
    _pendingAnchor = locator;
    _pendingPercent = percent.clamp(0.0, 1.0);
    _progressDirty = true;
    _progressDebounce?.cancel();
    _progressDebounce = Timer(progressDebounceInterval, () {
      _progressDebounce = null;
      unawaited(_flushPendingProgress());
    });
  }

  /// 立即落库挂起的进度（防抖到期 / 切后台 / 退出共用）。
  Future<void> _flushPendingProgress() async {
    _progressDebounce?.cancel();
    _progressDebounce = null;
    final session = _session;
    if (!_progressDirty || session == null) return;
    final anchor = _pendingAnchor ?? session.renderer.controller.currentLocator;
    final percent = _pendingAnchor != null
        ? _pendingPercent
        : session.renderer.controller.percent;
    _pendingAnchor = null;
    _progressDirty = false;
    await _writeProgress(anchor, percent);
  }

  Future<void> _writeProgress(ProgressAnchor anchor, double percent) async {
    try {
      await _progressDao.upsert(
        bookId: widget.bookId,
        locatorJson: anchor.locatorJson,
        percent: percent.clamp(0.0, 1.0),
        dirty: true,
      );
      await _booksDao.updateProgressInfo(
        widget.bookId,
        lastReadAt: DateTime.now(),
      );
      // M2 挂点：进度变更 → 同步触发器防抖 10s 单书推送（docs/04 §3）。
      // dispose 期的兜底落库不重挂防抖（退出推送由 flushProgress 立即承担）。
      if (!_disposed) _syncTriggers.onProgressChanged(widget.bookId);
    } catch (e, s) {
      _log.warn('进度落库失败（本地阅读不受影响）');
      _log.error('进度落库异常详情', e, s);
    }
  }

  // ============================================================================
  // 阅读时长（FR-208 基础版）
  // ============================================================================

  void _startReadingClock() {
    if (_readingClock != null) return;
    _readingClock = Timer.periodic(readingClockInterval, (_) {
      _readingSeconds++;
    });
  }

  /// 结算阅读时长：累加进 books.totalSeconds 并刷新 lastReadAt。
  Future<void> _flushReadingTime() async {
    if (_readingSeconds <= 0) return;
    final seconds = _readingSeconds;
    _readingSeconds = 0;
    try {
      await _booksDao.updateProgressInfo(
        widget.bookId,
        lastReadAt: DateTime.now(),
        addTotalSeconds: seconds,
      );
    } catch (e, s) {
      _log.warn('阅读时长落库失败');
      _log.error('阅读时长落库异常详情', e, s);
    }
  }

  // ============================================================================
  // 设置热应用（FR-206）与目录跳转（FR-108）
  // ============================================================================

  /// 下发设置到当前渲染器（applySettings 为契约外的公开约定扩展；
  /// 未实现的渲染器（如 epub 基线占位）静默跳过）。
  void _applySettings(ReaderSettings settings) {
    final renderer = _session?.renderer;
    if (renderer == null) return;
    try {
      (renderer as dynamic).applySettings(settings);
    } on NoSuchMethodError {
      _log.info('渲染器不支持设置热应用，跳过');
    }
  }

  void _jumpToTocEntry(TocEntry entry) {
    Navigator.of(context).pop(); // 先关抽屉
    unawaited(_session?.renderer.controller.jumpTo(entry));
  }

  Future<void> _openSettingsPanel() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const ReaderSettingsPanel(),
    );
  }

  /// 返回书库前的结算（PopScope 拦截系统返回/手势，保证先落库再退出）。
  Future<void> _exitWithFlush() async {
    _progressDebounce?.cancel();
    _progressDebounce = null;
    final session = _session;
    if (session != null && _progressDirty) {
      final anchor = session.renderer.controller.currentLocator;
      final percent = session.renderer.controller.percent;
      _progressDirty = false;
      _pendingAnchor = null;
      await _writeProgress(anchor, percent);
    }
    _readingClock?.cancel();
    _readingClock = null;
    await _flushReadingTime();
    if (mounted) Navigator.of(context).pop();
  }

  // ============================================================================
  // UI
  // ============================================================================

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_exitWithFlush());
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: _buildAppBar(context),
        endDrawer: _buildTocDrawer(context),
        body: switch (_state) {
          _OpeningState() => const Center(child: CircularProgressIndicator()),
          _ReadyState(:final session) => session.renderer.buildView(context),
          _PlaceholderState() => _buildPlaceholder(context),
          final _ErrorState error => _buildError(context, error.error),
          _MissingBookState() => const SizedBox.expand(),
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final book = _session?.book;
    final toc = switch (_state) {
      final _ReadyState s => s.toc,
      _ => const <TocEntry>[],
    };
    return AppBar(
      title: Text(
        book?.title ?? '阅读',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (toc.isNotEmpty)
          IconButton(
            key: const ValueKey('reader-toc-button'),
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '目录',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        IconButton(
          key: const ValueKey('reader-settings-button'),
          icon: const Icon(Icons.settings_outlined),
          tooltip: '阅读设置',
          onPressed: _openSettingsPanel,
        ),
      ],
    );
  }

  /// 目录抽屉（FR-108）：按层级缩进展示，点击跳转并关闭。
  Widget _buildTocDrawer(BuildContext context) {
    final toc = switch (_state) {
      final _ReadyState s => s.toc,
      _ => const <TocEntry>[],
    };
    if (toc.isEmpty) return const SizedBox.shrink();
    return Drawer(
      width: 320,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('目录', style: Theme.of(context).textTheme.titleMedium),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: toc.length,
                itemBuilder: (context, index) {
                  final entry = toc[index];
                  final level = entry.level.clamp(0, 4);
                  return ListTile(
                    contentPadding: EdgeInsets.only(
                      left: 16 + _tocIndentPerLevel * level,
                      right: 16,
                    ),
                    dense: level > 0,
                    title: Text(
                      entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: level == 0
                          ? Theme.of(context).textTheme.bodyMedium
                          : Theme.of(context).textTheme.bodySmall,
                    ),
                    onTap: () => _jumpToTocEntry(entry),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 占位书提示页（FR-402 前置：同步上线前只给说明）。
  Widget _buildPlaceholder(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_download_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          const Text('正文尚未下载'),
          const SizedBox(height: 8),
          Text(
            '同步功能上线后，可从云端获取正文',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            const Text('无法打开本书'),
            const SizedBox(height: 8),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('reader-retry-button'),
              onPressed: _open,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
