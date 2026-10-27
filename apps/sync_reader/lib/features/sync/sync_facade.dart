/// 同步编排门面（docs/03 §2 app 层）：惰性构建 SyncEngine，配置未就绪时
/// 一切方法安全 no-op 并报告 `SyncStateId.unconfigured`（FR-405）。
///
/// 装配关系：
/// - 适配器实例经 [SyncAdapterProvider] 注入——Phase C 起默认
///   [WebDavSyncAdapterProvider]（真实 WebDAV 传输，坚果云为第一目标）；
///   [InMemorySyncAdapterProvider] 保留给测试/演示注入。凭据缺失/认证失败
///   时引擎不构建，全部入口安全 no-op（见 [SyncFacade._ensureEngine]）；
/// - 凭据从安全存储读取（[SecureKeys]，FR-504），配置齐全才建引擎；
/// - 六种触发时机（docs/04 §3）全部经 [fullSync]/[pushBookMeta] 进入，
///   SyncEngine 自带单飞锁串行，触发器无需自建；
/// - 只 import sync_core 的导出（WebDavAdapter 由包出口统一提供）。
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_core/sync_core.dart';

import '../../app/providers.dart';
import '../../core/app_logger.dart';
import '../../core/ulid.dart';
import '../../data/secure/secure_credential_store.dart';
import '../../data/sync/drift_local_library.dart';
import '../../data/sync/drift_sync_store.dart';
import '../library/library_providers.dart' show bookDetailProvider;
import 'connection_test.dart';
import 'quota_gate.dart';
import 'sync_preferences.dart';
import 'sync_status.dart';
import 'sync_triggers.dart';

/// 后端适配器供应点（Phase C 切换点，FR-405）。
abstract interface class SyncAdapterProvider {
  /// 按配置创建适配器实例（每次构建引擎调用一次）。
  BackendAdapter create(BackendConfig config);
}

/// B2 内置供应：sync_core 的内存适配器（测试/演示注入用；数据不持久）。
final class InMemorySyncAdapterProvider implements SyncAdapterProvider {
  const InMemorySyncAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) => InMemoryAdapter();
}

/// Phase C 默认供应：真实 WebDAV 适配器工厂（docs/03 §4.3）。
///
/// 每次构建引擎新建实例（适配器持有 etag→rev 缓存与连接，随引擎生命周期
/// 经 `dispose` 释放）；凭据不经过本工厂——`connect(config)` 由门面用安全
/// 存储读出的配置调用，Basic 头只存在于请求内存中（NFR-03）。
final class WebDavSyncAdapterProvider implements SyncAdapterProvider {
  const WebDavSyncAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) => WebDavAdapter();
}

/// 触发来源（docs/04 §3 六种触发时机；downloadPlaceholder 不属于触发时机）。
enum SyncTriggerSource {
  /// 冷启动完成后 2s 全量。
  appStart,

  /// 切后台 > 5min 后回前台全量。
  lifecycleResume,

  /// 进度变更防抖 10s 单书推送。
  progressChange,

  /// 网络恢复全量。
  networkRestored,

  /// 前台期间每 15min 全量兜底。
  periodic,

  /// 手动：下拉刷新 / 设置页按钮。
  manual,
}

/// 同步门面。
final class SyncFacade {
  /// 构造；依赖全部注入（测试可整体替换）。
  SyncFacade({
    required this._adapterProvider,
    required this._credentials,
    required this._store,
    required this._library,
    required this._readPreferences,
    required this._onOutcome,
    SyncQuotaGate? quotaGate,
    Future<bool> Function()? wifiOnlyBlocked,
  }) {
    _quotaGate = quotaGate ?? SyncQuotaGate(store: _store);
    _wifiOnlyBlocked = wifiOnlyBlocked;
  }

  final SyncAdapterProvider _adapterProvider;
  final CredentialStore _credentials;
  final DriftSyncStore _store;
  final DriftLocalLibrary _library;
  final Future<SyncPreferencesSnapshot> Function() _readPreferences;
  final void Function(SyncStatusOutcome outcome) _onOutcome;
  late final SyncQuotaGate _quotaGate;
  late final Future<bool> Function()? _wifiOnlyBlocked;

  final _log = AppLogger();

  static const backendKey = 'webdav';

  SyncEngine? _engine;
  BackendAdapter? _adapter;

  /// 配额闸门（设置页/状态告警共用同一缓存）。
  SyncQuotaGate get quotaGate => _quotaGate;

  /// 是否已完成引擎构建（含配置检查）。
  bool get engineReady => _engine != null;

  /// 惰性构建引擎；配置未就绪或底层不可用 → null（安全 no-op 语义）。
  Future<SyncEngine?> _ensureEngine() async {
    if (_engine != null) return _engine;
    try {
      final config = await readConfig();
      if (config == null) return null;
      final adapter = _adapterProvider.create(config);
      await adapter.connect(config);
      final deviceId = await _store.loadOrCreateDeviceId(
        generate: generateUlid,
      );
      final engine = SyncEngine(
        adapter: adapter,
        store: _store,
        library: _library,
        transfer: _ensureTransfer(adapter),
        now: DateTime.now,
        identity: () async =>
            (deviceId: deviceId, deviceName: await _deviceName()),
        backendKey: backendKey,
        // 全量同步不自动批量下载正文（docs/04 §5.2：默认暂停待确认，
        // 占位书点开时按需下载）。
        autoDownloadContent: false,
      );
      _adapter = adapter;
      _engine = engine;
      await _quotaGate.refresh();
      return engine;
    } catch (e, s) {
      // 凭据读取失败（未配置）或平台层不可用：安全 no-op，不阻塞本地阅读。
      _log.warn('同步引擎未构建（配置未就绪）');
      _log.error('引擎构建异常详情', e, s);
      return null;
    }
  }

  TransferQueue _ensureTransfer(BackendAdapter adapter) {
    final gate = _quotaGate;
    return TransferQueue(
      adapter: adapter,
      retryPolicy: const RetryPolicy(),
      onBytes: (direction, bytes) {
        // 配额埋点（docs/04 §8.3）：持久层累计 + 内存缓存更新。
        final up = direction == TransferDirection.upload ? bytes : 0;
        final down = direction == TransferDirection.download ? bytes : 0;
        unawaited(gate.record(up, down).then((_) => _reportQuotaWarn()));
      },
      quotaGate: (est) =>
          gate.allowDownload(est, override: _overrideFlag?.call() ?? false),
    );
  }

  /// 配额越权标志（同步读取，由装配层接入偏好状态）。
  bool Function()? _overrideFlag;

  /// 装配层注入越权标志读取器。
  set overrideFlag(bool Function()? read) => _overrideFlag = read;

  void _reportQuotaWarn() {
    final text = SyncQuotaGate.warnText(_quotaGate.snapshot);
    _onOutcome(
      SyncStatusOutcome(stateId: SyncStateId.idle, quotaWarnText: text),
    );
  }

  Future<String> _deviceName() async {
    try {
      return Platform.localHostname;
    } catch (_) {
      return Platform.operatingSystem;
    }
  }

  // ── 配置读取（设置页展示 / 引擎构建共用；不含密码明文对外）─────────────

  /// 读当前后端配置；账号或应用密码缺失 → null（未配置）。
  Future<BackendConfig?> readConfig() async {
    final account = await _credentials.read(SecureKeys.webdavAccount);
    final secret = await _credentials.read(SecureKeys.webdavPassword);
    if (account == null || account.isEmpty) return null;
    if (secret == null || secret.isEmpty) return null;
    return BackendConfig(
      kind: BackendKind.webdav,
      baseUrl:
          await _credentials.read(SecureKeys.webdavBaseUrl) ??
          ConnectionTester.defaultBaseUrl,
      username: account,
      password: secret,
      rootPath:
          await _credentials.read(SecureKeys.webdavRootPath) ??
          ConnectionTester.defaultRootPath,
    );
  }

  // ── 同步入口（六种触发时机全部汇聚于此）───────────────────────────────

  /// 全量同步（docs/04 §4 五阶段）。
  ///
  /// 配置未就绪 → no-op 并报告 unconfigured；`autoSyncEnabled=false` 时仅
  /// 手动触发生效（docs/04 §3）。永不抛出。
  Future<SyncReport?> fullSync({
    SyncTriggerSource source = SyncTriggerSource.manual,
  }) async {
    final engine = await _ensureEngine();
    if (engine == null) {
      _onOutcome(const SyncStatusOutcome(stateId: SyncStateId.unconfigured));
      return null;
    }
    final prefs = await _readPreferences();
    if (source != SyncTriggerSource.manual && !prefs.autoSyncEnabled) {
      return null;
    }
    _onOutcome(
      SyncStatusOutcome(
        stateId: SyncStateId.syncing,
        quotaWarnText: SyncQuotaGate.warnText(_quotaGate.snapshot),
      ),
    );
    SyncReport? report;
    try {
      report = await engine.fullSync();
    } catch (e, s) {
      // 引擎自身永不抛出；防御性兜底（引擎外层如 store/库异常）。
      _log.error('全量同步外层异常', e, s);
      report = null;
    }
    _finishRound(report);
    return report;
  }

  /// 单书 meta 直达推送（进度防抖/退出阅读页的触发路径，docs/04 §3）。
  Future<SyncReport?> pushBookMeta(String bookId) async {
    final engine = await _ensureEngine();
    if (engine == null) {
      _onOutcome(const SyncStatusOutcome(stateId: SyncStateId.unconfigured));
      return null;
    }
    final prefs = await _readPreferences();
    if (!prefs.autoSyncEnabled) return null;
    SyncReport? report;
    try {
      report = await engine.pushBookMeta(bookId);
    } catch (e, s) {
      _log.error('单书推送外层异常', e, s);
    }
    _finishRound(report);
    return report;
  }

  /// 占位书正文按需下载（docs/04 §5.4；FR-402 的下载触发——点开占位书时
  /// 由 UI 调用。仅 Wi-Fi 限制在此把关；配额闸门在 TransferQueue 内）。
  Future<bool> downloadPlaceholder(String bookId) async {
    final engine = await _ensureEngine();
    if (engine == null) {
      _onOutcome(const SyncStatusOutcome(stateId: SyncStateId.unconfigured));
      return false;
    }
    if (await _wifiOnlyBlocked?.call() ?? false) {
      _onOutcome(
        SyncStatusOutcome(
          stateId: SyncStateId.idle,
          failureText: '当前为移动网络，"仅 Wi-Fi 下载正文"已开启，已暂停下载',
        ),
      );
      return false;
    }
    try {
      await engine.downloadContent(bookId);
      return true;
    } on SyncError catch (e) {
      _onOutcome(
        SyncStatusOutcome(
          stateId: SyncStateId.idle,
          failureText: syncErrorText(e),
        ),
      );
      return false;
    } catch (e, s) {
      _log.error('占位书下载外层异常', e, s);
      _onOutcome(
        const SyncStatusOutcome(
          stateId: SyncStateId.idle,
          failureText: '下载失败，请重试',
        ),
      );
      return false;
    }
  }

  /// 汇总一轮结果 → 状态上报。
  void _finishRound(SyncReport? report) {
    final SyncStateId id;
    final String? failure;
    if (report == null) {
      id = SyncStateId.failed;
      failure = '同步未完成，请稍后重试';
    } else if (report.phaseError != null) {
      id = SyncStateId.failed;
      failure = syncErrorText(report.phaseError!);
    } else if (!report.success) {
      id = SyncStateId.failed;
      String? firstError;
      for (final result in report.results) {
        if (!result.ok && result.error != null) {
          firstError = syncErrorText(result.error!);
          break;
        }
      }
      failure = firstError ?? '部分书籍同步失败';
    } else {
      id = SyncStateId.ok;
      failure = null;
    }
    _onOutcome(
      SyncStatusOutcome(
        stateId: id,
        lastSyncedAt: report?.finishedAt ?? DateTime.now(),
        failureText: failure,
        quotaWarnText: SyncQuotaGate.warnText(_quotaGate.snapshot),
        report: report,
      ),
    );
  }

  /// 清除凭据（危险区）：删除安全存储全部键 + 丢弃引擎（回到未配置态）。
  Future<void> clearCredentials() async {
    await _credentials.deleteAll();
    await _disposeEngine();
    _quotaGate.resetCache();
    _onOutcome(const SyncStatusOutcome(stateId: SyncStateId.unconfigured));
  }

  /// 保存凭据后重建引擎（连接向导落凭据时调用；下次同步生效）。
  Future<void> resetEngine() async {
    await _disposeEngine();
  }

  Future<void> _disposeEngine() async {
    _engine = null;
    final adapter = _adapter;
    _adapter = null;
    await adapter?.dispose();
  }

  /// 释放资源（进程级 provider dispose 调用）。
  Future<void> dispose() => _disposeEngine();
}

/// 偏好读取的门面侧投影（避免门面依赖 Riverpod 状态类型）。
class SyncPreferencesSnapshot {
  const SyncPreferencesSnapshot({
    this.autoSyncEnabled = true,
    this.wifiOnlyContent = true,
    this.quotaOverride = false,
  });

  final bool autoSyncEnabled;
  final bool wifiOnlyContent;
  final bool quotaOverride;
}

// ── Riverpod 装配 ──────────────────────────────────────────────────────

/// 凭据安全存储（进程级单例）。
final secureCredentialStoreProvider = Provider<CredentialStore>((ref) {
  return SecureCredentialStore();
});

/// drift → SyncStore 桥接。
final driftSyncStoreProvider = Provider<DriftSyncStore>((ref) {
  return DriftSyncStore(
    db: ref.watch(databaseProvider),
    credentials: ref.watch(secureCredentialStoreProvider),
    backendKey: 'webdav',
  );
});

/// drift → LocalLibrary 桥接（与导入共用文件布局）。
final driftLocalLibraryProvider = Provider<DriftLocalLibrary>((ref) {
  return DriftLocalLibrary(
    db: ref.watch(databaseProvider),
    fileStore: ref.watch(bookFileStoreProvider.future),
    backendKey: 'webdav',
  );
});

/// 配额闸门（进程级共享缓存）。
final quotaGateProvider = Provider<SyncQuotaGate>((ref) {
  return SyncQuotaGate(store: ref.watch(driftSyncStoreProvider));
});

/// 后端适配器供应点——Phase C 起默认真实 WebDAV（测试可整体覆盖）。
final syncAdapterProvider = Provider<SyncAdapterProvider>(
  (ref) => const WebDavSyncAdapterProvider(),
);

/// 同步门面（进程级单例；状态经 onOutcome 汇入内存侧状态）。
final syncFacadeProvider = Provider<SyncFacade>((ref) {
  final facade = SyncFacade(
    adapterProvider: ref.watch(syncAdapterProvider),
    credentials: ref.watch(secureCredentialStoreProvider),
    store: ref.watch(driftSyncStoreProvider),
    library: ref.watch(driftLocalLibraryProvider),
    readPreferences: () async {
      final prefs = ref.read(syncPreferencesProvider);
      return SyncPreferencesSnapshot(
        autoSyncEnabled: prefs.autoSyncEnabled,
        wifiOnlyContent: prefs.wifiOnlyContent,
        quotaOverride: prefs.quotaOverride,
      );
    },
    onOutcome: (outcome) {
      final notifier = ref.read(syncMemoryStatusProvider.notifier);
      if (outcome.quotaWarnText != null &&
          outcome.stateId == SyncStateId.idle &&
          outcome.report == null &&
          outcome.failureText == null &&
          outcome.lastSyncedAt == null) {
        // 纯配额告警更新：不打扰全局状态机。
        notifier.setQuotaWarn(outcome.quotaWarnText);
      } else {
        notifier.applyOutcome(outcome);
      }
      // 一轮同步落地了书库变更（新占位书/删除/进度覆盖）→ 一次性详情
      // provider 失效重取；books 列表与进度走 drift watch 自动刷新。
      if (outcome.report != null) {
        ref.invalidate(bookDetailProvider);
      }
    },
    quotaGate: ref.watch(quotaGateProvider),
    wifiOnlyBlocked: () async {
      final prefs = ref.read(syncPreferencesProvider);
      if (!prefs.wifiOnlyContent) return false;
      try {
        final types = await Connectivity().checkConnectivity();
        return types.contains(ConnectivityResult.mobile);
      } catch (_) {
        return false; // 平台层不可用（测试环境）不阻塞下载。
      }
    },
  )..overrideFlag = () => ref.read(syncPreferencesProvider).quotaOverride;
  ref.onDispose(facade.dispose);
  return facade;
});

/// 后端配置摘要（设置页后端卡片展示；不含密码）。
class SyncConfigSummary {
  const SyncConfigSummary({
    required this.account,
    required this.baseUrl,
    required this.rootPath,
  });

  final String account;
  final String baseUrl;
  final String rootPath;
}

/// 后端配置摘要（设置页后端卡片：未配置 → null）。
final syncConfigProvider = FutureProvider.autoDispose<SyncConfigSummary?>((
  ref,
) async {
  final config = await ref.watch(syncFacadeProvider).readConfig();
  if (config == null) return null;
  return SyncConfigSummary(
    account: config.username ?? '',
    baseUrl: config.baseUrl,
    rootPath: config.rootPath ?? '',
  );
});

/// 配额快照（设置页配额面板；同步轮次结束由 UI invalidate 刷新）。
final quotaSnapshotProvider = FutureProvider.autoDispose<QuotaSnapshot>((
  ref,
) async {
  final gate = ref.watch(quotaGateProvider);
  await gate.refresh();
  return gate.snapshot;
});

/// 持久化的上次全量同步时间（跨会话；与内存侧 lastSyncedAt 取较大者展示）。
final lastFullSyncAtProvider = FutureProvider.autoDispose<DateTime?>((ref) {
  return ref
      .watch(driftSyncStoreProvider)
      .cursorSnapshot('webdav')
      .then((c) => c.lastFullSyncAt);
});

/// 触发器宿主（六种触发时机，docs/04 §3；app 挂载/卸载由根组件驱动）。
final syncTriggersProvider = Provider<SyncTriggers>((ref) {
  final facade = ref.watch(syncFacadeProvider);
  final triggers = SyncTriggers(
    runSync: (source) => facade.fullSync(source: source),
    pushBookMeta: (bookId) async {
      await facade.pushBookMeta(bookId);
    },
    preferences: () => ref.read(syncPreferencesProvider),
  );
  ref.onDispose(triggers.detach);
  return triggers;
});
