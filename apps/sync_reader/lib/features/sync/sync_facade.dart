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
import '../../data/db/app_database.dart';
import '../../data/secure/secure_credential_store.dart';
import '../../data/sync/drift_local_library.dart';
import '../../data/sync/drift_sync_store.dart';
import '../library/library_providers.dart' show bookDetailProvider;
import 'connection_test.dart';
import 'credential_normalizer.dart';
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
    AppDatabase? db,
  }) {
    _quotaGate = quotaGate ?? SyncQuotaGate(store: _store);
    _wifiOnlyBlocked = wifiOnlyBlocked;
    _db = db;
  }

  final SyncAdapterProvider _adapterProvider;
  final CredentialStore _credentials;
  final DriftSyncStore _store;
  final DriftLocalLibrary _library;
  final Future<SyncPreferencesSnapshot> Function() _readPreferences;
  final void Function(SyncStatusOutcome outcome) _onOutcome;
  late final SyncQuotaGate _quotaGate;
  late final Future<bool> Function()? _wifiOnlyBlocked;

  /// 本地库（可选）：仅本地标记、墓碑查询与「上传到云端」的前置动作
  /// 需要它；未注入时相关动作安全 no-op（返回 false）。
  AppDatabase? _db;

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
  ///
  /// 读取侧做**防御性规范化**（去首尾空白 + 去零宽字符，baseUrl 另去尾
  /// 斜杠）：旧版本写入的凭据可能带空格/换行/零宽字符（复制粘贴残留），
  /// 这些字符会让坚果云按字节比对失败 → 401。写入侧（向导页落凭据）也
  /// 同样规范化，两侧都做才能覆盖"历史脏数据 + 新写入"两种来源。
  Future<BackendConfig?> readConfig() => readConfigFrom(_credentials);

  /// 从任意凭据存储读后端配置（静态版本；未配置 → null）。
  ///
  /// 与实例方法 [readConfig] 语义完全一致，拆成静态方法是为了让**不装配
  /// 门面**的场景复用同一套规范化与默认值规则（向导页的「使用已保存的
  /// 配置测试」只需凭据，不必构建引擎/存储/库）。
  static Future<BackendConfig?> readConfigFrom(CredentialStore store) async {
    final account = normalizeCredentialValue(
      await store.read(SecureKeys.webdavAccount) ?? '',
    );
    final secret = normalizeCredentialValue(
      await store.read(SecureKeys.webdavPassword) ?? '',
    );
    if (account.isEmpty) return null;
    if (secret.isEmpty) return null;
    final rawBaseUrl = await store.read(SecureKeys.webdavBaseUrl);
    final rawRootPath = await store.read(SecureKeys.webdavRootPath);
    final baseUrl = normalizeBaseUrlValue(rawBaseUrl ?? '');
    final rootPath = normalizeRootPathValue(rawRootPath ?? '');
    return BackendConfig(
      kind: BackendKind.webdav,
      baseUrl: baseUrl.isEmpty ? ConnectionTester.defaultBaseUrl : baseUrl,
      username: account,
      password: secret,
      rootPath: rootPath.isEmpty ? ConnectionTester.defaultRootPath : rootPath,
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
  ///
  /// 跳过两类书（docs/10 §4.7b / §4.7c）：
  /// - **仅本地**的书：用户明确选择"不上传"，读进度时也不能顺手推上云；
  /// - **本地已删除**的书：删除即移出书库（`books` 行已删），推送正常 meta
  ///   会与刚推上去的 tombstone 打架（云端复活一本书）。墓碑已确认且正文
  ///   未重新下载时一律跳过——正文已重新下载的情形按 docs/04 §7.2 的既有
  ///   语义走"正常 meta 胜出即复活"。
  Future<SyncReport?> pushBookMeta(String bookId) async {
    if (await _skipPush(bookId)) return null;
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

  /// 该书是否应跳过推送（仅本地 / 本地已删除且正文已删）。
  Future<bool> _skipPush(String bookId) async {
    final db = _db;
    if (db == null) return false;
    try {
      if (await db.localOnlyBooksDao.isLocalOnly(bookId)) return true;
      if (!await db.booksDao.hasTombstone(bookId)) return false;
      // 已删除：正文仍在本地（重新下载过）时允许复活推送。
      final book = await db.booksDao.getById(bookId);
      return book == null || (book.localPath ?? '').isEmpty;
    } catch (e, s) {
      _log.error('推送前置检查异常', e, s);
      return false; // 检查失败不阻断推送（本地优先：宁可多推一次）。
    }
  }

  /// 删除同步（FR-408，docs/04 §7.1）：在本地删除之后调用，推送 tombstone
  /// 到云端。用户显式操作，不受 autoSyncEnabled 门控；失败（离线/冲突）
  /// 由引擎记入 tombstone 账本，下次 fullSync 补推收敛——故静默不提示。
  Future<SyncReport?> deleteBook(String bookId) async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    SyncReport? report;
    try {
      report = await engine.deleteBook(bookId);
    } catch (e, s) {
      _log.error('删除推送外层异常', e, s);
    }
    return report;
  }

  // ── v1.1：「仅本地」状态的两条动作（docs/10 §4.7c / §4.8）─────────────

  /// 「上传到云端」：把一本仅本地的书上架到云端。
  ///
  /// 流程（docs/10 §4.7c 实施要点 4、6）：
  /// 1. 删除 `local_only_books` 标记（解除"不上传"）；
  /// 2. **清除该书的 `sync_state` 行（清 baseRev）**——diff 第 7a 行要求
  ///    「从未推送过（无 baseRev）」；曾同步过、后来被「从云端移除」的书仍
  ///    有 baseRev，不清就会落第 7b 行（保留本地、不推），上架不了；
  /// 3. 触发一次全量同步 → 走第 7a 行自动上架（推 meta + 传正文）。
  ///
  /// 未配置同步（无后端）→ false（安全 no-op，本地优先）；同步未全部成功 →
  /// false（UI 可提示重试）。
  Future<bool> uploadToCloud(String bookId) async {
    final db = _db;
    if (db == null) return false;
    // 本地已删除的书不上架（墓碑语义优先）。
    if (await db.booksDao.hasTombstone(bookId)) return false;
    await db.localOnlyBooksDao.clearLocalOnly(bookId);
    await db.clearBookSyncState(bookId);
    final report = await fullSync(source: SyncTriggerSource.manual);
    return report?.success ?? false;
  }

  /// 分组 meta 直达推送（FR-107 云端同步：新建/改名/排序后即时上云）。
  ///
  /// 用户显式操作，不受 autoSyncEnabled 门控（与 [deleteBook] 同款语义）：
  /// 失败（离线）不阻断本地操作——本地分组已改好，下次全量同步按"dirty"
  /// 补推（本地优先，docs/04 §1.3）。
  Future<SyncReport?> pushGroupMeta(String groupId) async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    SyncReport? report;
    try {
      report = await engine.pushGroupMeta(groupId);
    } catch (e, s) {
      _log.error('分组推送外层异常', e, s);
    }
    return report;
  }

  /// 分组删除同步（FR-107）：本地已软删（组内书回未分组）→ 推分组墓碑。
  ///
  /// 墓碑上云后其它设备同步即移除该分组；失败时本地保持"已删除"状态，
  /// 下次全量同步的分组 Diff 会再次走 deletePush 补推。
  Future<SyncReport?> deleteGroup(String groupId) async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    SyncReport? report;
    try {
      report = await engine.deleteGroup(groupId);
    } catch (e, s) {
      _log.error('分组删除推送外层异常', e, s);
    }
    return report;
  }

  /// 「从云端移除」：只删掉云端副本，各端本地副本保留且照常可读。
  ///
  /// 与 [deleteBook] 的区别（docs/10 §4.7c / §4.8）：
  /// - [deleteBook] = **全局删除**：写 tombstone 推云端，其它设备的书也会
  ///   从书库移除；
  /// - 本方法 = `BackendAdapter.deleteMeta`：**不写 tombstone**、不动本地
  ///   `books` 行、不动本地正文。本地 `sync_state` 的 baseRev 保持不变——
  ///   这正是让各端后续落 diff 第 7b 行（云端缺失 → 保留本地、不再上传）
  ///   的关键。
  ///
  /// 未配置同步 → false（安全 no-op）。
  Future<bool> removeFromCloud(String bookId) async {
    final engine = await _ensureEngine();
    if (engine == null) return false;
    try {
      await engine.removeCloudCopy(bookId);
      return true;
    } catch (e, s) {
      _log.error('从云端移除外层异常', e, s);
      return false;
    }
  }

  /// 云端书数量（v1.1 同步设置页「云端书库」卡展示，docs/10 §4.5）。
  ///
  /// 只读动作：走适配器 `listMetas` 计数（不建 diff、不传正文）；未配置
  /// （引擎未构建）→ null；清单失败折算 null（UI 显示「—」）。WebDAV/内存
  /// 实现的清单一次拉全（hasMore 恒 false），仅统计未删除的 meta 桩。
  Future<int?> countCloudBooks() async {
    final engine = await _ensureEngine();
    final adapter = _adapter;
    if (engine == null || adapter == null) return null;
    try {
      final listing = await adapter.listMetas();
      return listing.stubs.values.where((stub) => !stub.deleted).length;
    } catch (e, s) {
      _log.error('云端书目计数异常', e, s);
      return null;
    }
  }

  /// 云端书目清单（v1.1 云端书库管理页，docs/10 §4.8）。
  ///
  /// 只读动作：`listMetas` 取桩 → 逐条 `getMeta` 投影出书名 / 格式 / 大小
  /// （桩本身只有 bookId/rev，不含展示字段）。tombstone 排除做两层：
  /// 桩级 `deleted`（REST 后端直报）+ 内容级 `isTombstone`（WebDAV 的
  /// PROPFIND 看不到删除标记，必须拉内容判定，docs/04 §7.3）。
  ///
  /// 未配置 → null；`listMetas` 失败 → null（UI 显示失败态）；单条 meta
  /// 读取失败（损坏 / 中途消失）跳过该条不阻塞整页；全部单条都失败时
  /// 折算 null（大概率是网络问题，避免误报「云端书库为空」）。
  Future<List<CloudBookSummary>?> listCloudBooks() async {
    final engine = await _ensureEngine();
    final adapter = _adapter;
    if (engine == null || adapter == null) return null;
    try {
      final listing = await adapter.listMetas();
      final summaries = <CloudBookSummary>[];
      var failed = 0;
      for (final stub in listing.stubs.values) {
        if (stub.deleted) continue; // 桩级 tombstone（REST 直报）。
        final BookMeta? meta;
        try {
          meta = await adapter.getMeta(stub.bookId);
        } catch (e, s) {
          failed++;
          _log.error('云端单本 meta 读取异常（${stub.bookId}）', e, s);
          continue;
        }
        // 内容级 tombstone（WebDAV 桩恒 not-deleted，以内容为准）。
        if (meta == null || meta.isTombstone) continue;
        summaries.add(
          CloudBookSummary(
            bookId: meta.bookId,
            title: meta.book.title,
            format: meta.book.format,
            sizeBytes: meta.book.sizeBytes,
          ),
        );
      }
      if (summaries.isEmpty && failed > 0) return null;
      summaries.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      return summaries;
    } catch (e, s) {
      _log.error('云端书目清单异常', e, s);
      return null;
    }
  }

  // ── M3：云端孤儿清理与文件替换（docs/04 §7.1 规则 4 / FR-410）─────────

  /// 列出云端孤儿正文（`books/*` 中无 meta 引用者；docs/04 §7.1 规则 4）。
  /// 未配置 → null；引擎永不抛出，外层异常折算为带 error 的空清单。
  Future<CloudOrphanListing?> listCloudOrphans() async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    try {
      return await engine.listCloudOrphans();
    } catch (e, s) {
      _log.error('孤儿清单外层异常', e, s);
      return CloudOrphanListing(
        orphans: const [],
        error: SyncErrorMapper.fromException(e, context: '孤儿清单'),
      );
    }
  }

  /// 逐文件删除云端孤儿（UI 负责逐文件确认与可暂停；未配置 → null）。
  Future<SyncError?> deleteCloudOrphan(String name) async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    try {
      return await engine.deleteCloudOrphan(name);
    } catch (e, s) {
      _log.error('孤儿删除外层异常', e, s);
      return SyncErrorMapper.fromException(e, context: '孤儿删除 $name');
    }
  }

  /// 文件替换推送（FR-410）：本地行已由 app 更新（updateBookFileInfo +
  /// 重解析列）后调用，推 meta 并 overwrite 上传正文。用户显式操作，不受
  /// autoSyncEnabled 门控（对齐 deleteBook）；未配置 → null（本地优先，
  /// 本地替换已生效，调用方据此提示"仅替换本地"）。
  Future<SyncReport?> replaceBookContent(String bookId) async {
    final engine = await _ensureEngine();
    if (engine == null) return null;
    try {
      return await engine.replaceBookContent(bookId);
    } catch (e, s) {
      _log.error('替换推送外层异常', e, s);
      return null;
    }
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
      // 分组维度（FR-107）：书籍全绿但分组失败时也要提示。
      if (firstError == null) {
        for (final result in report.groupResults) {
          if (!result.ok && result.error != null) {
            firstError = syncErrorText(result.error!);
            break;
          }
        }
      }
      failure = firstError ?? '部分书籍/分组同步失败';
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
    // 本地库：仅本地标记 / 墓碑判定 / 「上传到云端」的前置动作。
    db: ref.watch(databaseProvider),
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

/// 云端书目摘要（云端书库管理页行模型，docs/10 §4.8）。
///
/// 由云端 meta 的 `BookInfo` 投影而来，不含本地字段；「本地已下载 / 仅云端」
/// 的本地状态由页面用 books 表比对（`localPath` 非空 = 已下载），不进本类。
class CloudBookSummary {
  const CloudBookSummary({
    required this.bookId,
    required this.title,
    required this.format,
    required this.sizeBytes,
  });

  final String bookId;
  final String title;

  /// `txt | epub | md | pdf`（徽标展示用，转大写显示）。
  final String format;
  final int sizeBytes;
}

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
