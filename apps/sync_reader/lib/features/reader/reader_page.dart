/// 阅读页（FR-201/206/207/208 基础版 + FR-108 目录抽屉 + FR-209 音量键翻页）。
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
/// 阅读时长（FR-208）：页面就绪且 app resumed 时每秒累计；切后台/退出时
/// `updateProgressInfo(addTotalSeconds)` 落库并刷新 lastReadAt，同时把各秒
/// 按 tick 时刻的自然日拆分逐日写入 reading_days（按天统计，本地表）。
///
/// 设置热应用（FR-206）：监听 ReaderSettingsRepository.changes，经渲染器的
/// `applySettings` 约定扩展方法下发（契约之外的公开约定，三个真实渲染器均实现）。
///
/// 音量键翻页（FR-209，Android 专属）：设置开启且会话就绪时启用平台通道
/// 拦截并订阅按键事件（音量上键 = 上一页，音量下键 = 下一页）；dispose/
/// 会话切换时一律停用，恢复系统音量键默认行为。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../app/providers.dart';
import '../../core/app_logger.dart';
import '../../core/design_tokens.dart'
    show AppRadius, AppSpacing, ReaderPalette;
import '../../data/db/app_database.dart' show Book;
import '../../data/db/daos/books_dao.dart';
import '../../data/db/daos/progress_dao.dart';
import '../../data/db/daos/reading_days_dao.dart';
import '../../features/sync/placeholder_download.dart';
import '../../features/sync/sync_facade.dart';
import '../../features/sync/sync_triggers.dart';
import 'contract/book_file.dart';
import 'contract/book_renderer.dart';
import 'contract/parsed_book.dart';
import 'contract/progress_anchor.dart';
import 'contract/reader_settings.dart';
import 'contract/reader_settings_repository.dart';
import 'contract/toc_entry.dart';
import 'contract/toc_fingerprint.dart';
import 'reader_key_action.dart';
import 'reader_brightness.dart';
import 'reader_chrome.dart';
import 'reading_day.dart';
import 'settings/settings_panel.dart';
import 'volume_key_page_turn.dart';

/// 进度落库防抖窗口（docs/03 §3.1：翻页/滚动后 3s）。
const Duration progressDebounceInterval = Duration(seconds: 3);

/// 阅读时长累计步长（每秒一跳，切后台/退出结算）。
const Duration readingClockInterval = Duration(seconds: 1);

/// 目录条目每级缩进量。
const double _tocIndentPerLevel = 16;

/// 控制条显隐动画时长（原型 --dur）。
const Duration _chromeTransition = Duration(milliseconds: 200);

/// 首次进入轻提示的停留时长（docs/10 §4.4/Q10：2.6s 自动淡出）。
const Duration _hintDuration = Duration(milliseconds: 2600);

/// 轻提示淡出动画时长。
const Duration _hintFade = Duration(milliseconds: 300);

/// Aa 面板桌面/移动形态断点（docs/10 §4.4：桌面 >860 右侧抽屉）。
const double _aaDesktopBreakpoint = 860;

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

/// 占位书（云端有、本地无正文；FR-402 提供下载入口）。
final class _PlaceholderState extends _PageState {
  const _PlaceholderState(this.title);

  final String title;
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

  /// 阅读页键盘焦点（桌面端翻页按键的拦截点）。
  ///
  /// 包在正文 Stack 外层：无论焦点当前落在阅读页内哪个控件上（如刚拖完
  /// 进度滑块），按键事件沿焦点链冒泡都会先经这里判给翻页——否则 Slider
  /// 会吃掉方向键去改进度值，造成「按方向键进度乱跳」。
  final FocusNode _readerFocus = FocusNode();

  // DAO 与设置仓库在 initState 取好引用（dispose 中不允许再用 ref）。
  late final ProgressDao _progressDao;
  late final BooksDao _booksDao;
  late final ReadingDaysDao _readingDaysDao;
  late final ReaderSettingsRepository _settingsRepo;

  /// M2 同步触发器（进度防抖推送的挂点；取引用避免 dispose 期再用 ref）。
  late final SyncTriggers _syncTriggers;
  StreamSubscription<ReaderSettings>? _settingsSub;

  // —— 音量键翻页（FR-209，Android 专属）——
  late final VolumeKeyPageTurn _volumeKeys = VolumeKeyPageTurn();
  StreamSubscription<String>? _volumeKeySub;

  _PageState _state = const _OpeningState();

  // —— 沉浸态（v1.1 A8/Q10）——

  /// 控制条（顶/底条）是否可见；默认全隐（沉浸），点正文中部唤出/再点收起。
  bool _controlsVisible = false;

  /// 首次进入轻提示是否可见（2.6s 自动淡出）。
  bool _hintVisible = false;
  Timer? _hintTimer;

  /// 进度滑块拖动中：拖动期间滑块显示本地值（节流），松手一次性跳转。
  bool _sliderDragging = false;
  double _sliderValue = 0;

  /// 最近一次生效的阅读设置（打开链路 load 后与设置热应用时更新；
  /// 控制条配色随阅读主题走，与正文一致）。
  ReaderSettings _readerSettings = ReaderSettings.defaults;

  /// 控制条/目录抽屉配色（取自当前阅读主题的权威 ReaderPalette）。
  ReaderPalette get _readerPalette => _readerSettings.theme.palette;

  /// 页面是否已进入 dispose（dispose 期的兜底落库不再触发同步防抖）。
  bool _disposed = false;

  // —— 进度管线（FR-207）——
  Timer? _progressDebounce;
  bool _progressDirty = false;
  ProgressAnchor? _pendingAnchor;
  double _pendingPercent = 0;

  // —— 阅读时长（FR-208 基础版 + 按天归账）——
  Timer? _readingClock;
  int _readingSeconds = 0;

  /// 本次会话各自然日的秒数账本（键为 [readingDayKey] 日键）：
  /// 每 tick 记 1 秒到"该 tick 时刻"的日键，跨午夜的会话按秒自然拆分；
  /// 结算时逐日写入 reading_days 后清空（与 [_readingSeconds] 同生共死）。
  final Map<String, int> _secondsByDay = {};

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
    _readingDaysDao = ref.read(readingDaysDaoProvider);
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
    _hintTimer?.cancel();
    _hintTimer = null;
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
    // 音量键翻页（FR-209）：任何退出路径都恢复系统音量键默认行为
    // （先停用、后释放服务，保证 disable 请求先于通道释放完成）。
    unawaited(_disableVolumeKeys().then((_) => _volumeKeys.dispose()));
    _settingsSub?.cancel();
    _readerFocus.dispose();
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
    // 会话切换（重试/占位下载后重开）：先恢复系统音量键默认行为，
    // 新会话就绪后再按设置重新启用（FR-209）。
    unawaited(_disableVolumeKeys());
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
      // 占位书：不进渲染器（阅读器不接收无正文的书），给下载入口（FR-402）。
      final title = book.title;
      setState(() => _state = _PlaceholderState(title));
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
      _readerSettings = settings;

      // toc 解析与渲染器创建并行：toc 失败不影响打开（目录按钮降级隐藏）。
      final parsedFuture = handler.parseMetadata(file).catchError((Object _) {
        // 解析失败降级：空目录 + 空指纹（指纹门跳过比对，不阻塞打开）。
        const emptyToc = <TocEntry>[];
        return ParsedBook(
          title: '',
          author: '',
          toc: emptyToc,
          tocFingerprint: TocFingerprint.compute(emptyToc),
        );
      });

      final savedProgress = await _progressDao.getByBookId(widget.bookId);
      var anchor = savedProgress == null
          ? ProgressAnchor.empty
          : ProgressAnchor.fromRaw(
              savedProgress.locatorJson,
              savedProgress.percent,
            );

      renderer = await handler.createRenderer(file, settings, anchor);

      // 指纹门（docs/05 §3.3 恢复规则 1，全格式生效）：解析目录非空且与
      // 入库指纹不一致时，locator 精确恢复不可信（解析器升级/规则调整）→
      // 把锚点降级为 raw（percent 保持），restore 走 percent 分支。
      // 目录为空（解析失败）时跳过比对，不得阻塞打开。
      final parsed = await parsedFuture;
      if (anchor.hasProgress &&
          parsed.toc.isNotEmpty &&
          parsed.tocFingerprint != book.tocFingerprint) {
        anchor = ProgressAnchor(
          locatorJson: '{"type":"raw","ratio":${anchor.percent}}',
          percent: anchor.percent,
        );
      }

      try {
        await renderer.controller.restore(anchor);
      } catch (e, s) {
        // 恢复失败降级为从头阅读，不阻塞打开。
        _log.warn('进度恢复失败，从头开始');
        _log.error('恢复异常详情', e, s);
      }
      if (!mounted) {
        renderer.dispose();
        return;
      }
      renderer.controller.onProgressChanged = _onProgressChanged;

      final toc = parsed.toc;
      setState(() {
        _state = _ReadyState(
          session: _ReaderSession(book: book!, renderer: renderer!),
          toc: toc,
        );
      });
      // 沉浸态进入提示（Q10）：每次进入阅读器显示，2.6s 自动淡出。
      _showEntryHint();
      unawaited(_updateWindowTitle(book.title));
      if (_isAppResumed) _startReadingClock();
      // 音量键翻页（FR-209）：会话就绪后按设置启用（Android 重建约定：
      // 原生状态随引擎重建重置，此处由 Dart 主动 enable 一次恢复）。
      unawaited(_syncVolumeKeys(settings.volumeKeyPageTurn));
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
  /// 同时刷新控制条（进度滑块/百分比/页码随阅读位置即时更新）。
  void _onProgressChanged(ProgressAnchor locator, double percent) {
    _pendingAnchor = locator;
    _pendingPercent = percent.clamp(0.0, 1.0);
    _progressDirty = true;
    if (mounted) setState(() {});
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
  // 阅读时长（FR-208 基础版 + 按天归账）
  // ============================================================================

  void _startReadingClock() {
    if (_readingClock != null) return;
    _readingClock = Timer.periodic(readingClockInterval, (_) {
      _recordReadingTick(DateTime.now());
    });
  }

  /// 一次 tick：1 秒同时计入总会话时长与"该 tick 时刻"的自然日账本。
  /// 生产 tick 与测试钩子 [debugTick] 共用此实现，避免两份逻辑。
  void _recordReadingTick(DateTime now) {
    _readingSeconds++;
    final day = readingDayKey(now);
    _secondsByDay[day] = (_secondsByDay[day] ?? 0) + 1;
  }

  /// 测试钩子（不进生产路径）：等价一次 tick，按传入时刻归日。
  /// 配合 [debugFlushReadingDays] 可注入跨午夜时刻序列验证按日拆分。
  @visibleForTesting
  void debugTick(DateTime now) => _recordReadingTick(now);

  /// 测试钩子（不进生产路径）：触发阅读时长结算（books.totalSeconds 与
  /// reading_days 按日归账）并等待写库完成。
  @visibleForTesting
  Future<void> debugFlushReadingDays() => _flushReadingTime();

  /// 结算阅读时长：先按原路径并入 books.totalSeconds 并刷新 lastReadAt
  /// （行为不变），再把日账本逐日写入 reading_days（FR-208 按天统计）。
  ///
  /// 两条写路径各自 try/catch：按天记录失败只降级日志，不影响总时长落库
  /// （本地优先，统计缺一天不伤主链路）。账本先快照清空再落库，防止结算
  /// 重入（切后台 + dispose 交叠）造成重复计数。
  Future<void> _flushReadingTime() async {
    if (_readingSeconds <= 0) return;
    final seconds = _readingSeconds;
    final byDay = Map<String, int>.of(_secondsByDay);
    _readingSeconds = 0;
    _secondsByDay.clear();
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
    if (byDay.isEmpty) return;
    try {
      for (final MapEntry(key: day, value: daySeconds) in byDay.entries) {
        await _readingDaysDao.addSeconds(widget.bookId, day, daySeconds);
      }
    } catch (e, s) {
      _log.warn('按天阅读时长落库失败（不影响总时长）');
      _log.error('按天阅读时长落库异常详情', e, s);
    }
  }

  // ============================================================================
  // 设置热应用（FR-206）与目录跳转（FR-108）
  // ============================================================================

  /// 下发设置到当前渲染器（applySettings 为契约外的公开约定扩展；
  /// 未实现的渲染器（如 epub 基线占位）静默跳过）。
  void _applySettings(ReaderSettings settings) {
    setState(() {
      _readerSettings = settings; // 控制条配色/夜间亮度/提示文案跟随
    });
    final renderer = _session?.renderer;
    if (renderer != null) {
      try {
        (renderer as dynamic).applySettings(settings);
      } on NoSuchMethodError {
        _log.info('渲染器不支持设置热应用，跳过');
      }
    }
    // 音量键翻页开关热应用（FR-209）：设置面板改动立即生效/停用。
    unawaited(_syncVolumeKeys(settings.volumeKeyPageTurn));
  }

  // ============================================================================
  // 沉浸态辅助（v1.1 A8/Q10）
  // ============================================================================

  /// 首次进入轻提示：显示 2.6s 后自动淡出（重复进入重新计时）。
  void _showEntryHint() {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() => _hintVisible = true);
    _hintTimer = Timer(_hintDuration, () {
      _hintTimer = null;
      if (mounted) setState(() => _hintVisible = false);
    });
  }

  // ============================================================================
  // 音量键翻页（FR-209，Android 专属）
  // ============================================================================

  /// 按设置同步音量键拦截：仅 Android 且设置开启且会话就绪时启用；
  /// 启用时先确保事件订阅挂上（服务内部也是先订阅后 enable，顺序兜底）。
  Future<void> _syncVolumeKeys(bool settingEnabled) async {
    final enabled = Platform.isAndroid && settingEnabled && _session != null;
    try {
      await _volumeKeys.setEnabled(enabled);
      if (!enabled) return;
      _volumeKeySub ??= _volumeKeys.events.listen(_onVolumeKeyEvent);
    } catch (e, s) {
      _log.warn('音量键翻页启用失败（不影响阅读）');
      _log.error('音量键翻页异常详情', e, s);
    }
  }

  /// 音量键事件 → 翻页。语义冻结：音量上键 = 上一页，音量下键 = 下一页。
  void _onVolumeKeyEvent(String event) {
    final controller = _session?.renderer.controller;
    if (controller == null) return;
    unawaited(
      event == 'up' ? controller.previousPage() : controller.nextPage(),
    );
  }

  /// 停用音量键拦截并取消事件订阅（dispose / 会话切换共用）：try/finally
  /// 保证订阅取消失败也不影响恢复系统音量键默认行为。
  Future<void> _disableVolumeKeys() async {
    final sub = _volumeKeySub;
    _volumeKeySub = null;
    try {
      await sub?.cancel();
    } finally {
      await _volumeKeys.setEnabled(false);
    }
  }

  void _jumpToTocEntry(TocEntry entry) {
    Navigator.of(context).pop(); // 先关抽屉
    unawaited(_session?.renderer.controller.jumpTo(entry));
    // 立即刷新一次控制条（页码/章名/滑块的精确值随后由节流上报收敛），
    // 否则跳章后「当前章」标签要等下一次交互才更新。
    setState(() {});
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
  // UI（v1.1 A8 沉浸态：无 AppBar，控制条为浮层，点中部唤出/收起）
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
        // 沉浸态（Q10）：不设 AppBar，正文占满全屏；顶/底控制条与热区
        // 均为 body 内浮层，endDrawer 承载目录抽屉。
        endDrawer: _buildTocDrawer(context),
        body: switch (_state) {
          _OpeningState() => const Center(child: CircularProgressIndicator()),
          final _ReadyState ready => _buildReadyBody(context, ready),
          _PlaceholderState() => _buildPlaceholder(context),
          final _ErrorState error => _buildError(context, error.error),
          _MissingBookState() => const SizedBox.expand(),
        },
      ),
    );
  }

  /// 就绪态：正文 + 热区 + 顶/底控制条 + 首次轻提示（自下而上叠放）。
  /// B3：夜间系背景下整屏套亮度滤镜（背景与正文一起变暗/变亮）。
  ///
  /// v1.3：正文视图包一层 [readerBodyInsets] 垂直内缩——上留顶条高、
  /// 下留底条高（+ 系统状态栏/导航栏），**结构上保证正文永不被控制条
  /// 遮挡**（对齐原型 `.rd-stage` 的上下留白）。
  Widget _buildReadyBody(BuildContext context, _ReadyState ready) {
    final book = ready.session.book;
    return ReaderBrightnessFilter(
      isNightTheme: _readerSettings.theme.isNight,
      brightness: _readerSettings.nightBrightness,
      child: Focus(
        focusNode: _readerFocus,
        autofocus: true,
        onKeyEvent: _onReaderKeyEvent,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              // 内缩带（顶条/底条之下）用阅读背景色铺满，避免露出 Scaffold
              // 底色形成色带。
              color: _readerPalette.bg,
              child: Padding(
                padding: readerBodyInsets(context),
                child: ready.session.renderer.buildView(context),
              ),
            ),
            _buildHotZones(ready),
            _buildTopBar(context, book, ready.toc),
            _buildBottomBar(context, ready),
            _buildEntryHint(context),
          ],
        ),
      ),
    );
  }

  /// 桌面端键盘翻页：↑/←/PageUp = 上一页，↓/→/PageDown/空格 = 下一页。
  ///
  /// 本节点是正文的焦点链祖先，按键从焦点控件冒泡上来时先到这里；命中
  /// 翻页键即返回 handled，压掉 Slider 等控件的默认方向键行为（改进度值）。
  /// 弹层（设置面板/目录抽屉）是独立路由焦点域，不受此影响。
  ///
  /// 判定规则见 [readerKeyAction]：**按键自动重复不翻页**（按住方向键时
  /// 系统连发重复事件，旧实现每次重复都翻一页——表现是「按下后一直翻页
  /// 停不下来」；现在按一次 = 翻一页，松手即停）。
  KeyEventResult _onReaderKeyEvent(FocusNode node, KeyEvent event) {
    if (_session == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final action = readerKeyAction(event);
    switch (action) {
      case ReaderKeyAction.ignore:
        return KeyEventResult.ignored;
      case ReaderKeyAction.swallow:
        // 自动重复：吃掉事件但不翻页（按住不放不再连翻）。
        return KeyEventResult.handled;
      case ReaderKeyAction.turnNext:
      case ReaderKeyAction.turnPrevious:
        final controller = _session!.renderer.controller;
        unawaited(
          action == ReaderKeyAction.turnNext
              ? controller.nextPage()
              : controller.previousPage(),
        );
        return KeyEventResult.handled;
    }
  }

  // —— 点击热区（A8）：左右两翼 22% 翻页，中间 56% 唤出/收起控制条 ——

  /// 热区始终生效（翻页是高频操作）；全部使用 translucent 命中行为：
  /// 快点由热区 onTap 接管（翻页/唤出），拖动在竞技场中让位给正文
  /// PageView/ListView（滚动不受影响）。翻页走 [ReaderController] 的
  /// nextPage/previousPage——与音量键翻页（FR-209）完全同一路径。
  ///
  /// 中区点击**一律**唤出/收起控制条（含点在正文上，桌面与移动端一致）：
  /// 桌面正文列（720）占中区宽度的 90%+，「点空白才出菜单」没有可点的
  /// 空白——实测字形盒 + 容差会把段落间隙也判成文字，菜单几乎唤不出来
  /// （v1.2 B6 的「文字优先」判定已按实际使用反馈移除）。文字选择语义
  /// 由拖拽承担：本回调只在 tap（无位移）时触发，与拖动选择不冲突。
  Widget _buildHotZones(_ReadyState ready) {
    final controller = ready.session.renderer.controller;
    final narrow = MediaQuery.sizeOf(context).width <= kReaderNarrowBreakpoint;
    return Positioned.fill(
      child: Row(
        children: [
          Expanded(
            flex: 22,
            child: GestureDetector(
              key: const ValueKey('reader-hot-prev'),
              behavior: HitTestBehavior.translucent,
              onTap: narrow
                  ? _toggleControls
                  : () => unawaited(controller.previousPage()),
            ),
          ),
          Expanded(
            flex: 56,
            child: GestureDetector(
              key: const ValueKey('reader-hot-mid'),
              behavior: HitTestBehavior.translucent,
              onTapUp: (_) => _toggleControls(),
            ),
          ),
          Expanded(
            flex: 22,
            child: GestureDetector(
              key: const ValueKey('reader-hot-next'),
              behavior: HitTestBehavior.translucent,
              onTap: narrow
                  ? _toggleControls
                  : () => unawaited(controller.nextPage()),
            ),
          ),
        ],
      ),
    );
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (_controlsVisible) {
        // 唤出菜单后「点按显示菜单」提示使命完成。
        _hintTimer?.cancel();
        _hintVisible = false;
      }
    });
  }

  // —— 顶/底控制条 ——

  /// 控制条显隐动画（原型 .reader-top/.reader-bottom 的 translateY）。
  Widget _chromeSlide({required Widget child, required bool fromTop}) {
    return AnimatedSlide(
      duration: _chromeTransition,
      curve: Curves.easeOutCubic,
      offset: _controlsVisible
          ? Offset.zero
          : (fromTop ? const Offset(0, -1) : const Offset(0, 1)),
      child: IgnorePointer(ignoring: !_controlsVisible, child: child),
    );
  }

  /// 顶部条：返回 / 书名（+当前章副标题）/ 目录 / 齿轮（半透明浮层，A8）。
  ///
  /// 骨架对齐原型 `.rd-top`（v1.3）：条高 [kReaderTopBarHeight]（54），
  /// 标题区为**上下两行**——书名 13.5/600 + 当前章 11.5 muted（窄视口
  /// 隐藏副标题，同原型 `.rd-title span`）；三个图标按钮为 34×34 点击区
  /// + 19px 图标（原型 `.rd-btn` / `.rd-btn .ico`）。
  Widget _buildTopBar(BuildContext context, Book book, List<TocEntry> toc) {
    final palette = _readerPalette;
    final chapterTitle = _currentChapterTitle(toc);
    final narrow = MediaQuery.sizeOf(context).width <= kReaderNarrowBreakpoint;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _chromeSlide(
        fromTop: true,
        child: Container(
          decoration: BoxDecoration(
            color: palette.bg.withValues(alpha: 0.88),
            border: Border(bottom: BorderSide(color: palette.rule)),
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: kReaderTopBarHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: Row(
                  children: [
                    _buildTopBarIcon(
                      tooltip: '返回',
                      icon: Icons.arrow_back,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: palette.fg,
                            ),
                          ),
                          if (chapterTitle != null && !narrow)
                            Text(
                              chapterTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (toc.isNotEmpty)
                      _buildTopBarIcon(
                        key: const ValueKey('reader-toc-button'),
                        tooltip: '目录',
                        icon: Icons.menu_book_outlined,
                        onPressed: () =>
                            _scaffoldKey.currentState?.openEndDrawer(),
                      ),
                    _buildTopBarIcon(
                      key: const ValueKey('reader-settings-button'),
                      tooltip: '阅读设置',
                      icon: Icons.settings_outlined,
                      onPressed: _openSettingsPanel,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 顶条图标按钮：34×34 点击区 + 19px 图标（原型 `.rd-btn` / `.ico`）。
  ///
  /// 用 `IconButton` 但显式收紧约束：`constraints` 定死 34×34、
  /// `padding: EdgeInsets.zero`、`iconSize: 19`，并用
  /// `MaterialTapTargetSize.shrinkWrap` 关闭 Material 默认的 48×48
  /// 命中区扩展（否则按钮实际仍是 48×48，与原型不符）。
  Widget _buildTopBarIcon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    Key? key,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      icon: Icon(icon),
      iconSize: 19,
      color: _readerPalette.fg,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 34, height: 34),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      onPressed: onPressed,
    );
  }

  /// 底部条：章节名 + 进度滑块（拖动跳转）+ 轨道下方一行小字。
  ///
  /// 骨架对齐原型 `.rd-bottom`（v1.3）：条高 [kReaderBottomBarHeight]（58），
  /// 窄视口 ≤460 为 [kReaderBottomBarHeightNarrow]（54）；左侧章节名
  /// （12px muted，窄视口隐藏，同原型 `.rd-chap`）；中间滑块区 = 轨道
  /// （4px 细线 + 12px 圆点手柄）+ 下方一行 11px muted 小字（左右分列）。
  Widget _buildBottomBar(BuildContext context, _ReadyState ready) {
    final palette = _readerPalette;
    final chapterTitle = _currentChapterTitle(ready.toc);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final narrow = screenWidth <= kReaderNarrowBreakpoint;
    final height = narrow ? kReaderBottomBarHeightNarrow : kReaderBottomBarHeight;
    final (leftMeta, rightMeta) = _bottomBarMeta(ready);
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: _chromeSlide(
        fromTop: false,
        child: Container(
          decoration: BoxDecoration(
            color: palette.bg.withValues(alpha: 0.9),
            border: Border(top: BorderSide(color: palette.rule)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: height,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? AppSpacing.s3 : AppSpacing.s5,
                ),
                child: Row(
                  children: [
                    if (!narrow && chapterTitle != null)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: screenWidth * 0.26,
                        ),
                        child: Text(
                          chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                      ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: 22,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 4,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                                activeTrackColor: palette.fg.withValues(
                                  alpha: 0.7,
                                ),
                                inactiveTrackColor: palette.fg.withValues(
                                  alpha: 0.14,
                                ),
                                thumbColor: palette.fg,
                                overlayColor: palette.fg.withValues(
                                  alpha: 0.12,
                                ),
                              ),
                              child: _buildProgressSlider(ready),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                leftMeta,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.muted,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              Text(
                                rightMeta,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: palette.muted,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 进度滑块：拖动中仅刷新本地值（节流），松手一次性跳转
  /// （[ReaderPercentJump] 能力，txt/epub/md 实现；不支持的渲染器无操作）。
  Widget _buildProgressSlider(_ReadyState ready) {
    final percent = ready.session.renderer.controller.percent.clamp(0.0, 1.0);
    return Slider(
      key: const ValueKey('reader-progress-slider'),
      value: _sliderDragging ? _sliderValue : percent,
      onChanged: (value) => setState(() {
        _sliderDragging = true;
        _sliderValue = value;
      }),
      onChangeEnd: (value) {
        _sliderDragging = false;
        // 能力接口与 BookRenderer 无父子关系，用模式匹配取实现对象。
        final renderer = ready.session.renderer;
        if (renderer case final ReaderPercentJump jump) {
          unawaited(jump.jumpToPercent(value));
        }
        setState(() {});
        // 焦点归还阅读页根节点：Slider 点过即持有焦点，方向键会被它吃掉
        // 去改进度值（表现为按↑↓时进度乱跳）；归还后方向键重新判给翻页。
        _readerFocus.requestFocus();
      },
    );
  }

  /// 底条小字行内容（左「本章 N / M 页」、右「全书 X%」）。
  ///
  /// 页码取自渲染器的 [ReaderPageInfoProvider.currentPageInfo]（章内页码，
  /// 0 起）；页码不可用（滚动模式/连续排版渲染器）时左侧退化为纯百分比，
  /// 右侧留空——避免同一百分比在左右重复出现。
  (String, String) _bottomBarMeta(_ReadyState ready) {
    final renderer = ready.session.renderer;
    final pct = (renderer.controller.percent.clamp(0.0, 1.0) * 100).round();
    final info = switch (renderer) {
      ReaderPageInfoProvider p => p.currentPageInfo,
      _ => null,
    };
    if (info == null || info.$2 <= 0) return ('$pct%', '');
    return ('本章 ${info.$1 + 1} / ${info.$2} 页', '全书 $pct%');
  }

  // —— 首次进入轻提示（A8/Q10：2.6s 自动淡出） ——

  Widget _buildEntryHint(BuildContext context) {
    final palette = _readerPalette;
    return Positioned(
      left: 0,
      right: 0,
      // v1.3：对齐原型 `.rd-hint`（bottom 84px）——避开底条。
      bottom: 84,
      child: IgnorePointer(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedOpacity(
            opacity: _hintVisible ? 1 : 0,
            duration: _hintFade,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: palette.fg.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Text(
                _entryHintText,
                style: TextStyle(fontSize: 12, color: palette.bg),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 首次进入轻提示文案（随翻页方式变化，B5/B6；对齐原型 rd-hint）。
  String get _entryHintText => switch (_readerSettings.pageMode) {
    ReaderPageMode.page => switch (_readerSettings.pageTurnAxis) {
      ReaderPageTurnAxis.horizontal => '点按空白处显示菜单 · 左右滑动翻页',
      ReaderPageTurnAxis.vertical => '点按空白处显示菜单 · 上滑／下滑翻页',
    },
    ReaderPageMode.scroll => '点按空白处显示菜单 · 滚动阅读',
  };

  /// 当前章标题（顶/底条与目录抽屉共用；经渲染器的
  /// isTocEntryCurrent 能力比对，取第一个命中条目）。
  String? _currentChapterTitle(List<TocEntry> toc) {
    final renderer = _session?.renderer;
    if (renderer == null) return null;
    for (final entry in toc) {
      if (renderer.isTocEntryCurrent(entry)) return entry.title;
    }
    return null;
  }

  // —— Aa 排版面板（A9：桌面右侧抽屉 / 移动底部弹层） ——

  Future<void> _openSettingsPanel() {
    final isDesktop = MediaQuery.widthOf(context) > _aaDesktopBreakpoint;
    if (isDesktop) {
      // 桌面（>860）：右侧全高抽屉（对齐原型 .type-panel）。
      return showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: '关闭阅读设置',
        barrierColor: Theme.of(context).colorScheme.scrim
            .withValues(alpha: 0.4),
        transitionDuration: _chromeTransition,
        pageBuilder: (context, animation, secondaryAnimation) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            key: const ValueKey('reader-aa-drawer'),
            color: Theme.of(context).colorScheme.surface,
            child: SizedBox(
              // 336 = 原型 `.rd-drawer{width:336px}`（单元 2 对齐）。
              width: 336,
              height: double.infinity,
              child: const ReaderSettingsPanel(),
            ),
          ),
        ),
      );
    }
    // 移动（≤860）：底部弹层（原型 ≤700 宽时抽屉变底部弹层：
    // 顶部圆角、max-height 78%、无拖拽条）。
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.heightOf(sheetContext) * 0.78,
        ),
        child: const ReaderSettingsPanel(key: ValueKey('reader-aa-sheet')),
      ),
    );
  }

  /// 目录抽屉（FR-108 + A8 重做）：右侧抽屉，头部「目录 + 章数 + 关闭」，
  /// 按层级缩进展示，当前章高亮并带「当前」标记（isTocEntryCurrent 比对），
  /// 点击跳转并关闭。
  ///
  /// 配色归属（对齐原型 `.rd-drawer`）：**阅读页内的浮层抽屉属于应用外壳**
  /// ——底色取外壳 `surface`，文字取 `onSurface` / `onSurfaceVariant`，
  /// 强调色取品牌色 `primary`；**正文与顶/底控制条才属于阅读主题**。
  /// 因此本抽屉不再使用阅读主题 palette（阅读主题底色会随夜间背景变黑，
  /// 与原型「抽屉始终是浅色面板」的观感不符）。
  Widget _buildTocDrawer(BuildContext context) {
    final toc = switch (_state) {
      final _ReadyState s => s.toc,
      _ => const <TocEntry>[],
    };
    if (toc.isEmpty) return const SizedBox.shrink();
    // 应用外壳配色（浅/深跟随系统，不受阅读主题影响）。
    final scheme = Theme.of(context).colorScheme;
    final brand = scheme.primary;
    return Drawer(
      // 336 = 原型 `.rd-drawer{width:336px}`（与 Aa 排版面板同宽）。
      width: 336,
      // 底色 = 应用外壳 surface（原型 `--surface`）：抽屉 Material 自身也要
      // 用外壳色，否则 M3 默认 surfaceContainerLow 会在边缘露出来。
      backgroundColor: scheme.surface,
      // 原型 `.rd-drawer` 为直角面板（无圆角），与 Aa 排版面板一致。
      shape: const RoundedRectangleBorder(),
      child: Container(
        // 只描左边线（原型 `.rd-drawer{border-left:1px solid var(--border)}`）；
        // 不铺底色——底色由 Drawer 的 Material 提供，条目 hover 的
        // `--surface-3` 底色（应用主题 hoverColor）才能透出来。
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.outline)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                // 原型 `.rd-drawer-head{padding:var(--s4)}`（16 四周）。
                padding: const EdgeInsets.all(AppSpacing.s4),
                child: Row(
                  children: [
                    Text(
                      '目录',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    // 章数胶囊（原型 `.rd-pill`：11px、padding 2/8、全圆、
                    // 浅底 + muted 字）。
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                      child: Text(
                        '${toc.length} 章',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s2),
                    // 关闭（原型 `.rd-btn`：34×34 点击区 + 19px 图标）。
                    IconButton(
                      key: const ValueKey('reader-toc-close'),
                      tooltip: '关闭',
                      icon: const Icon(Icons.close),
                      iconSize: 19,
                      color: scheme.onSurface,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 34,
                        height: 34,
                      ),
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // 头与列表之间的 1px 分隔线（原型 `.rd-drawer-head` 下边框）。
              Divider(height: 1, color: scheme.outline),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.s2,
                    horizontal: AppSpacing.s2,
                  ),
                  itemCount: toc.length,
                  itemBuilder: (context, index) {
                    final entry = toc[index];
                    final level = entry.level.clamp(0, 4);
                    final isCurrent =
                        _session?.renderer.isTocEntryCurrent(entry) ?? false;
                    final isSub = level >= 1;
                    // 二级项左侧引导线（原型 `.rd-toc-item.lv2::before`）：
                    // 1px 竖线，位于文字左侧 3px（原型 lv2 文字 24px / 线 20px）。
                    const double guideGap = 3;
                    final textLeft = 12 + _tocIndentPerLevel * level;
                    return InkWell(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      onTap: () => _jumpToTocEntry(entry),
                      child: Stack(
                        children: [
                          Container(
                            padding: EdgeInsets.only(
                              left: textLeft,
                              right: 12,
                              top: 9,
                              bottom: 9,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(AppRadius.sm),
                              color: isCurrent
                                  ? brand.withValues(alpha: 0.14)
                                  : Colors.transparent,
                            ),
                            child: Row(
                              children: [
                                // 二级标题前缀「·」（原型 `.rd-toc-item.lv2
                                // .t::before`）：弱化文字色，与左缩进一起
                                // 标示层级。txt 书无二级项，肉眼不可见；
                                // epub/md 有二级项时会显现。
                                if (isSub) ...[
                                  Text(
                                    '·',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(width: 7),
                                ],
                                Expanded(
                                  child: Text(
                                    entry.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: level == 0 ? 13 : 12.5,
                                      fontWeight: isCurrent
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: isCurrent
                                          ? brand
                                          : scheme.onSurface.withValues(
                                              alpha: isSub ? 0.72 : 0.82,
                                            ),
                                    ),
                                  ),
                                ),
                                if (isCurrent) ...[
                                  const SizedBox(width: AppSpacing.s2),
                                  // 「当前」徽标（原型 `.rd-toc-cur`）：品牌色
                                  // 18% 透明底 + 品牌色字，不再是实心深色药丸。
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: brand.withValues(alpha: 0.18),
                                      borderRadius: BorderRadius.circular(
                                        AppRadius.full,
                                      ),
                                    ),
                                    child: Text(
                                      '当前',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: brand,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isSub)
                            Positioned(
                              left: textLeft - guideGap - 1,
                              top: 0,
                              bottom: 0,
                              child: Container(width: 1, color: scheme.outline),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 占位书提示页（FR-402）：提供"下载正文"入口，成功后重新走打开链路。
  Widget _buildPlaceholder(BuildContext context) {
    final title = switch (_state) {
      final _PlaceholderState s => s.title,
      _ => '',
    };
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
            '该书来自云端同步，下载正文后即可阅读',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('reader-download-button'),
            onPressed: _downloadPlaceholderContent,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('下载正文'),
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }

  /// 占位书正文下载（FR-402）：复用统一入口（Wi-Fi/配额把关 + snackbar
  /// 反馈）；成功后重新打开（localPath 已转正 → 正常进渲染器）。
  Future<void> _downloadPlaceholderContent() async {
    final title = switch (_state) {
      final _PlaceholderState s => s.title,
      _ => '',
    };
    final ok = await downloadPlaceholderBook(
      context,
      ref,
      bookId: widget.bookId,
      title: title,
    );
    if (!ok || !mounted) return;
    _open();
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
