/// 同步触发时机（docs/04 §3 六种，全部经门面进入，SyncEngine 自带单飞锁
/// 串行，触发器无需自建锁）：
///
/// 1. 冷启动完成后 2s 全量（[attach] 挂起）；
/// 2. 切后台 > 5min 后回前台全量（[didChangeAppLifecycleState]）；
/// 3. 进度变更防抖 10s 单书 meta 推送（[onProgressChanged]；退出阅读页
///    立即推送走 [flushProgress]）；
/// 4. 网络恢复全量（connectivity none → 有网）；
/// 5. 前台期间每 15min 定时全量兜底；
/// 6. 手动全量（[manualSync]，下拉刷新/设置页）。
///
/// 配置项 `autoSyncEnabled=false` 时仅手动生效（docs/04 §3）。
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:sync_core/sync_core.dart';

import 'sync_facade.dart';
import 'sync_preferences.dart';

/// 触发器宿主：持有全部定时器/订阅/生命周期观察。
final class SyncTriggers with WidgetsBindingObserver {
  /// 构造。依赖注入以便测试：[runSync]/[pushBookMeta]/[preferences] 必给，
  /// [connectivityStream]/[now]/各时延参数可选覆盖。
  SyncTriggers({
    required this._runSync,
    required this._pushBookMeta,
    SyncPreferences Function()? preferences,
    Stream<List<ConnectivityResult>>? connectivityStream,
    DateTime Function()? now,
    this.startDelay = const Duration(seconds: 2),
    this.progressDebounce = const Duration(seconds: 10),
    this.periodicInterval = const Duration(minutes: 15),
    this.resumeAwayThreshold = const Duration(minutes: 5),
  }) {
    _preferences = preferences;
    _connectivityStream = connectivityStream;
    _now = now ?? DateTime.now;
  }

  final Future<SyncReport?> Function(SyncTriggerSource source) _runSync;
  final Future<void> Function(String bookId) _pushBookMeta;
  late final SyncPreferences Function()? _preferences;
  late final Stream<List<ConnectivityResult>>? _connectivityStream;
  late final DateTime Function() _now;

  /// 启动后全量同步的延迟。
  final Duration startDelay;

  /// 进度变更防抖窗口。
  final Duration progressDebounce;

  /// 前台定时全量间隔。
  final Duration periodicInterval;

  /// 回前台触发全量的"离台最短时长"。
  final Duration resumeAwayThreshold;

  Timer? _startTimer;
  Timer? _periodicTimer;
  final Map<String, Timer> _progressTimers = {};
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  DateTime? _awayAt;
  bool _connected = true;
  bool _attached = false;

  bool get _autoSyncEnabled => _preferences?.call().autoSyncEnabled ?? true;

  // ── 挂载 / 卸载 ──────────────────────────────────────────────────────

  /// 挂载：启动定时器 + 生命周期观察 + 网络监听。幂等。
  void attach() {
    if (_attached) return;
    _attached = true;
    WidgetsBinding.instance.addObserver(this);
    // 1. 启动后 2s 全量。
    _startTimer = Timer(
      startDelay,
      () => _autoSync(SyncTriggerSource.appStart),
    );
    // 5. 前台 15min 定时全量兜底。
    _periodicTimer = Timer.periodic(
      periodicInterval,
      (_) => _autoSync(SyncTriggerSource.periodic),
    );
    // 4. 网络恢复全量。
    try {
      _connectivitySub =
          (_connectivityStream ?? Connectivity().onConnectivityChanged).listen(
            _onConnectivityChanged,
          );
    } on Object {
      // 平台层不可用（测试环境等）：放弃网络恢复触发，不影响其余时机。
      _connectivitySub = null;
    }
  }

  /// 卸载：取消全部定时器/订阅/观察（幂等；测试/容器 dispose 调用）。
  void detach() {
    if (!_attached) return;
    _attached = false;
    WidgetsBinding.instance.removeObserver(this);
    _startTimer?.cancel();
    _startTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    for (final timer in _progressTimers.values) {
      timer.cancel();
    }
    _progressTimers.clear();
    unawaited(_connectivitySub?.cancel());
    _connectivitySub = null;
    _awayAt = null;
  }

  // ── 生命周期（触发时机 2）────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final at = _now();
    if (state == AppLifecycleState.resumed) {
      handleResume(at);
    } else {
      // inactive/hidden/paused：记录离台起点（桌面端 hidden、移动端 paused）。
      _awayAt ??= at;
    }
  }

  /// 回前台：离台 > 5min 才全量（docs/04 §3 第 2 行）。
  void handleResume(DateTime at) {
    final away = _awayAt;
    _awayAt = null;
    if (away != null && at.difference(away) > resumeAwayThreshold) {
      _autoSync(SyncTriggerSource.lifecycleResume);
    }
  }

  // ── 网络（触发时机 4）────────────────────────────────────────────────

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final connected = results.any((r) => r != ConnectivityResult.none);
    final was = _connected;
    _connected = connected;
    if (connected && !was) {
      _autoSync(SyncTriggerSource.networkRestored);
    }
  }

  // ── 进度（触发时机 3）────────────────────────────────────────────────

  /// 阅读进度变更（阅读页落库后调用）：防抖 10s → 单书 meta 推送。
  void onProgressChanged(String bookId) {
    _progressTimers[bookId]?.cancel();
    _progressTimers[bookId] = Timer(progressDebounce, () {
      _progressTimers.remove(bookId);
      _pushIfAuto(bookId);
    });
  }

  /// 仅取消某书挂起的防抖定时器（不推送）。
  ///
  /// 阅读页 dispose 时调用：防抖定时器的生命周期与页面绑定（而非容器），
  /// 保证页面卸载后无悬挂 Timer（测试环境的 pending-timer 不变式也依赖此）。
  void cancelProgressDebounce(String bookId) {
    _progressTimers.remove(bookId)?.cancel();
  }

  /// 立即推送某书待传进度（退出阅读页时调用；取消挂起的防抖）。
  Future<void> flushProgress(String bookId) async {
    _progressTimers.remove(bookId)?.cancel();
    await _pushIfAuto(bookId);
  }

  Future<void> _pushIfAuto(String bookId) async {
    try {
      if (!_autoSyncEnabled) return;
      await _pushBookMeta(bookId);
    } on Object {
      // 容器销毁竞态/底层异常：触发器永远不向上抛（同步是旁路）。
    }
  }

  // ── 手动（触发时机 6）────────────────────────────────────────────────

  /// 手动全量同步（不受 autoSyncEnabled 限制，docs/04 §3）。
  Future<SyncReport?> manualSync() => _runSync(SyncTriggerSource.manual);

  // ── 内部 ─────────────────────────────────────────────────────────────

  /// 自动同步总闸：关闭时仅手动（[manualSync]）生效。
  void _autoSync(SyncTriggerSource source) {
    try {
      if (!_autoSyncEnabled) return;
    } on Object {
      return; // 偏好读取失败（容器销毁竞态）：按关闭处理。
    }
    unawaited(_runSync(source));
  }
}
