import 'dart:async';

import '../backend/backend_adapter.dart';
import '../conflict/conflict_resolver.dart';
import '../diff/diff_engine.dart';
import '../internal/semaphore.dart';
import '../model/book_meta.dart';
import '../model/sync_error.dart';
import '../store/local_library.dart';
import '../store/sync_store.dart';
import '../transfer/transfer_queue.dart';

/// 逐书同步结果。
class BookSyncResult {
  BookSyncResult({
    required this.bookId,
    this.decision,
    required this.ok,
    this.error,
  });

  final String bookId;
  final SyncDecision? decision;
  final bool ok;
  final SyncError? error;

  @override
  String toString() =>
      'BookSyncResult($bookId, $decision, ok=$ok${error == null ? '' : ', error=$error'})';
}

/// 一次同步的报告：逐书结果、字节数、起止时间（可序列化不要求）。
class SyncReport {
  SyncReport({required this.startedAt});

  final DateTime startedAt;
  DateTime? finishedAt;

  /// 阶段级失败（清单拉取/本地读取等全局性错误）；逐书错误在 [results] 内。
  SyncError? phaseError;

  final List<BookSyncResult> results = [];

  /// bookId → 本轮 Diff 决策（与 results 对应，诊断/断言用）。
  final Map<String, SyncDecision> decisions = {};

  /// 阶段 3 PullMetas 的实际峰值并发（诊断/测试断言）。
  int pullPeakConcurrency = 0;

  /// If-None-Match 命中 304 的次数（条件请求生效统计）。
  int conditionalHits = 0;

  /// 本轮传输字节数（正文；meta 体积忽略）。
  int bytesUp = 0;
  int bytesDown = 0;

  bool get success => phaseError == null && results.every((r) => r.ok);

  void add(BookSyncResult result) => results.add(result);

  @override
  String toString() =>
      'SyncReport(results=${results.length}, success=$success, '
      'up=$bytesUp, down=$bytesDown)';
}

/// tombstone GC 报告（docs/04 §7.3）。
class GcReport {
  GcReport({
    required this.localPurged,
    required this.cloudDeleted,
    required this.errors,
  });

  /// 本地账本清理条数（30 天保留期）。
  final int localPurged;

  /// 云端 tombstone meta 删除数（90 天保留期）。
  final int cloudDeleted;
  final List<SyncError> errors;

  bool get success => errors.isEmpty;
}

/// 云端孤儿清单结果（docs/04 §7.1 规则 4）。
class CloudOrphanListing {
  const CloudOrphanListing({required this.orphans, this.error});

  /// 无 meta 引用的 `books/` 文件（app 逐文件展示供用户确认）。
  final List<CloudBookFile> orphans;

  /// 清单阶段失败（如网络）时非 null；此时 [orphans] 为空表。
  final SyncError? error;

  bool get success => error == null;
}

/// 同步引擎：五阶段状态机（docs/04 §4）
/// `PullListing → Diff → PullMetas → PushMetas → Transfer → 落游标`。
///
/// - 幂等可重放：任何阶段失败只记入 [SyncReport]，状态回 Idle；
///   无内存残留依赖，下次触发自动收敛（docs/04 §1.3）；
/// - 单飞：并发调用在内部串行化（状态机不允许两个同步并存）；
/// - 冲突路径：写前 `expectedRev = baseRev`；[RevConflict] → 拉远端 →
///   [ConflictResolver] 合并 → 以远端当前 rev 重试恰一次；再冲突 →
///   `ConflictUnresolvable`（docs/04 §6.1）。
class SyncEngine {
  SyncEngine({
    required BackendAdapter adapter,
    required SyncStore store,
    required LocalLibrary library,
    required TransferQueue transfer,
    ConflictResolver? resolver,
    DiffEngine? differ,
    required DateTime Function() now,
    required Future<({String deviceId, String deviceName})> Function() identity,
    this.backendKey = 'webdav',
    this.autoDownloadContent = false,
  }) : _adapter = adapter,
       _store = store,
       _library = library,
       _transfer = transfer,
       _resolver = resolver ?? const ConflictResolver(),
       _differ = differ ?? const DiffEngine(),
       _now = now,
       _identity = identity;

  final BackendAdapter _adapter;
  final SyncStore _store;
  final LocalLibrary _library;
  final TransferQueue _transfer;
  final ConflictResolver _resolver;
  final DiffEngine _differ;
  final DateTime Function() _now;
  final Future<({String deviceId, String deviceName})> Function() _identity;

  /// 后端键（docs/05 §5：'webdav' | 'server:{libraryId}'）。
  final String backendKey;

  /// 全量同步是否自动批量下载缺失正文（docs/04 §5.2：默认关闭等待用户确认，
  /// 打开占位书时按需下载）。
  final bool autoDownloadContent;

  /// 拉取 meta 并发上限（docs/04 §4 阶段 3：并发 2）。
  static const int pullConcurrency = 2;

  final Semaphore _pullSlots = Semaphore(pullConcurrency);
  Future<void>? _lock;
  bool _layoutEnsured = false;

  // ── 公开入口 ──────────────────────────────────────────────────────────

  /// 全量同步（docs/04 §4 五阶段）。永不抛出：一切失败记录进报告。
  Future<SyncReport> fullSync() => _withLock(_runFullSync);

  /// 单书 meta 直达推送（docs/04 §3 第三行：进度防抖，不拉清单，
  /// 阶段 4 的推送子集）。冲突时同样走合并 + 重试恰一次。
  Future<SyncReport> pushBookMeta(String bookId) => _withLock(() async {
    final report = SyncReport(startedAt: _now());
    final id = await _identity();
    await _pushMetaForBook(
      bookId: bookId,
      report: report,
      decision: SyncDecision.pushLocal,
      deviceId: id.deviceId,
      deviceName: id.deviceName,
    );
    report.finishedAt = _now();
    return report;
  });

  /// 删除同步（docs/04 §7.1）：组 tombstone → 尽力推送云端。
  ///
  /// 本地书库行的移除由调用方（app 删除流程）负责——本地优先，与本方法
  /// 正交且顺序不限：本地行已删时基组依次回退"公共祖先缓存 → 远端 meta"。
  /// 云端推送失败（如离线）时 tombstone 已入账本（pushed=false），由下次
  /// [fullSync] 补推，最终收敛。冲突语义：删除与远端修改同序但"后操作
  /// 优先"——用户点击删除的时刻更晚，tombstone 以 `rev = max(双端)+1、
  /// updatedAt = now` 覆盖（docs/04 §7.2 行 2 的对称面）。
  Future<SyncReport> deleteBook(String bookId) =>
      _withLock(() => _deleteBook(bookId));

  Future<SyncReport> _deleteBook(String bookId) async {
    final report = SyncReport(startedAt: _now());
    final id = await _identity();
    try {
      final snap = await _library.book(bookId);
      var base = snap == null
          ? null
          : await _library.buildLocalMeta(
              bookId,
              rev: 1,
              deviceId: id.deviceId,
              deviceName: id.deviceName,
              now: _now(),
            );
      base ??= _parseMeta(
        (await _store.syncState(bookId, backendKey))?.lastSyncedMetaJson,
      );
      // 删除前确认云端现状：无 meta（从未上云或已被 GC）→ 只记账本；
      // 已是 tombstone → 幂等确认。二者都不再造云端条目。
      final remote = await _adapter.getMeta(bookId);
      if (remote == null || remote.isTombstone) {
        await _store.markTombstonePushed(bookId);
        if (base != null) {
          await _store.recordTombstone(
            TombstoneLedgerEntry(
              bookId: bookId,
              deletedAt: _now(),
              pushed: true,
              contentHash: base.book.contentHash,
            ),
          );
        }
        report.add(
          BookSyncResult(
            bookId: bookId,
            decision: SyncDecision.deletePush,
            ok: true,
          ),
        );
        report.finishedAt = _now();
        return report;
      }
      base ??= remote;
      final deletedAt = _now();
      await _store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: bookId,
          deletedAt: deletedAt,
          pushed: false,
          contentHash: base.book.contentHash,
        ),
      );
      final pushed = await _pushTombstoneOnce(
        base: base,
        deletedAt: deletedAt,
        expectedRev: remote.rev,
        deviceId: id.deviceId,
        deviceName: id.deviceName,
      );
      if (pushed) {
        await _store.markTombstonePushed(bookId);
        report.add(
          BookSyncResult(
            bookId: bookId,
            decision: SyncDecision.deletePush,
            ok: true,
          ),
        );
      } else {
        // 双次冲突：账本已在（pushed=false），留给 fullSync 补推。
        report.add(
          BookSyncResult(
            bookId: bookId,
            decision: SyncDecision.deletePush,
            ok: false,
            error: ConflictUnresolvable('删除推送两次冲突，留待下轮同步补推'),
          ),
        );
      }
    } catch (e) {
      // 传输类失败（如离线）同样已入账本，恢复后补推。
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: SyncDecision.deletePush,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '删除推送 $bookId'),
        ),
      );
    }
    report.finishedAt = _now();
    return report;
  }

  /// 云端孤儿清单（docs/04 §7.1 规则 4）：列出 `books/` 下**无 meta 引用**
  /// 的正文文件。判定 = 文件名主干（去掉最后一个 `.ext`）不在 meta 清单的
  /// bookId 集合中；tombstone meta 同样算引用（FR-408：删除不删云端正文，
  /// tombstoned 书的正文不列为孤儿）。app 层逐文件展示供用户确认，确认后
  /// 经 [deleteCloudOrphan] 逐个删除（可暂停）。
  Future<CloudOrphanListing> listCloudOrphans() => _withLock(() async {
    try {
      final files = await _adapter.listBookFiles();
      final listing = await _adapter.listMetas();
      final orphans = <CloudBookFile>[];
      for (final file in files) {
        final bookId = _bookIdOfFileName(file.name);
        if (!listing.stubs.containsKey(bookId)) orphans.add(file);
      }
      return CloudOrphanListing(orphans: orphans);
    } catch (e) {
      return CloudOrphanListing(
        orphans: const [],
        error: SyncErrorMapper.fromException(e, context: '云端孤儿清单'),
      );
    }
  });

  /// 删除单个云端孤儿文件（docs/04 §7.1 规则 4 手动清理工具的执行入口）。
  ///
  /// app 层负责逐文件确认与暂停；本方法只执行删除（404 视为幂等成功），
  /// 成功返回 null，失败返回分类错误（引擎"永不抛出"约定）。
  Future<SyncError?> deleteCloudOrphan(String name) => _withLock(() async {
    try {
      await _adapter.deleteBookFile(name);
      return null;
    } catch (e) {
      return SyncErrorMapper.fromException(e, context: '删除云端孤儿 $name');
    }
  });

  /// FR-410 文件替换（docs/05 §6 不变式 3 的显式出口）：app 层已完成换文件
  /// 落盘与本地行更新（[LocalLibrary.updateBookFileInfo]），本方法推 meta
  /// （复用 baseRev/冲突合并重试路径）并以 overwrite 上传正文。
  ///
  /// - 进度字段完全不参与：percent/locator 原样保留；他端因 tocFingerprint
  ///   变化自动降级 percent（docs/05 §3.3 规则 2，机制已存在）；
  /// - 接收端按"meta hash ≠ 本地 hash → 正常下载覆盖"处理（非损坏）；
  /// - 收敛行为：meta 推送成功而正文上传失败（如离线）时，错误记入报告，
  ///   meta 已上云；重试本方法即重新推 meta（rev+1）并重传正文；meta 推送
  ///   失败时跳过正文上传（避免云端"新正文 + 旧 meta"的哈希不一致窗口）；
  /// - 无本地书/无正文文件（`localContentPath` 为 null）→ [Corruption]
  ///   记入报告，不抛出。
  Future<SyncReport> replaceBookContent(String bookId) =>
      _withLock(() => _replaceBookContent(bookId));

  Future<SyncReport> _replaceBookContent(String bookId) async {
    final report = SyncReport(startedAt: _now());
    final id = await _identity();
    try {
      final snap = await _library.book(bookId);
      final declaredHash = snap?.meta?.book.contentHash;
      if (snap == null || declaredHash == null) {
        throw Corruption('本地书库不存在该书，无法替换正文（$bookId）');
      }
      final path = await _library.localContentPath(bookId);
      if (path == null) {
        throw Corruption('本地正文文件缺失，无法替换正文（$bookId）');
      }
      // 步骤 1：推 meta（expectedRev=baseRev；RevConflict → 合并 → 重试恰
      // 一次）。行内已是新 hash/size（app 已更新），合并保持本端 book 信息
      // 时即推送新文件指征。
      final before = report.results.length;
      await _pushMetaForBook(
        bookId: bookId,
        report: report,
        decision: SyncDecision.pushLocal,
        deviceId: id.deviceId,
        deviceName: id.deviceName,
      );
      final metaPushed =
          report.results.length > before && report.results.last.ok;
      if (!metaPushed) {
        // meta 推送失败（冲突不可解/网络等）→ 跳过正文上传：避免云端出现
        // "新正文 + 旧 meta"的哈希不一致窗口（他端下载将误判损坏）。
        // 错误已由 _pushMetaForBook 记入报告，用户恢复后重试本方法即可。
        report.finishedAt = _now();
        return report;
      }
      // 步骤 2：上传正文（overwrite：显式替换跳过"远端已有不同版本"检查）。
      try {
        await _transfer.uploadFile(
          bookId,
          filePath: path,
          contentHash: declaredHash,
          overwrite: true,
        );
      } catch (e) {
        report.add(
          BookSyncResult(
            bookId: bookId,
            decision: SyncDecision.pushLocal,
            ok: false,
            error: SyncErrorMapper.fromException(e, context: '替换正文上传 $bookId'),
          ),
        );
      }
    } catch (e) {
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: SyncDecision.pushLocal,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '替换正文 $bookId'),
        ),
      );
    }
    report.finishedAt = _now();
    return report;
  }

  /// `books/` 文件名（`{bookId}.{ext}`）→ bookId 主干；无扩展名时原样返回。
  static String _bookIdOfFileName(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 组 tombstone 并推送；`RevConflict` 时以"后操作优先"压过远端重试
  /// 恰一次。成功时回写 sync_state（baseRev/公共祖先缓存）。返回是否成功。
  Future<bool> _pushTombstoneOnce({
    required BookMeta base,
    required DateTime deletedAt,
    required int expectedRev,
    required String deviceId,
    required String deviceName,
  }) async {
    final bookId = base.bookId;
    var expected = expectedRev;
    var rev = await _store.nextRev(bookId, atLeast: expected + 1);
    for (var attempt = 0; attempt < 2; attempt++) {
      final tomb = _makeTombstone(
        base,
        rev: rev,
        deletedAt: deletedAt,
        deviceId: deviceId,
        deviceName: deviceName,
      );
      try {
        await _adapter.putTombstone(tomb, expectedRev: expected);
        await _store.saveSyncState(
          BookSyncStateSnapshot(
            bookId: bookId,
            backendKey: backendKey,
            baseRev: tomb.rev,
            lastSyncedMetaJson: tomb.toJsonString(),
            lastSyncedAt: _now(),
          ),
        );
        return true;
      } on RevConflict catch (e) {
        if (attempt == 1) return false;
        expected = e.remoteRev;
        rev = await _store.nextRev(bookId, atLeast: e.remoteRev + 1);
      }
    }
    return false;
  }

  /// 全量同步的前置补推：账本中 `pushed=false` 的 tombstone（离线删除的
  /// 收敛路径，docs/04 §7.1）。云端无该书 meta 或已是 tombstone → 直接
  /// 标记已推送；否则以公共祖先/远端为基组推送一次。
  Future<void> _pushPendingTombstones(
    MetaListing listing,
    SyncReport report,
    ({String deviceId, String deviceName}) id,
  ) async {
    for (final entry in await _store.tombstoneLedger()) {
      if (entry.pushed || !listing.stubs.containsKey(entry.bookId)) continue;
      try {
        final remote = await _adapter.getMeta(entry.bookId);
        if (remote == null || remote.isTombstone) {
          await _store.markTombstonePushed(entry.bookId);
          continue;
        }
        final cached = _parseMeta(
          (await _store.syncState(
            entry.bookId,
            backendKey,
          ))?.lastSyncedMetaJson,
        );
        final pushed = await _pushTombstoneOnce(
          base: cached ?? remote,
          deletedAt: entry.deletedAt,
          expectedRev: remote.rev,
          deviceId: id.deviceId,
          deviceName: id.deviceName,
        );
        await _store.markTombstonePushed(entry.bookId);
        report.add(
          BookSyncResult(
            bookId: entry.bookId,
            decision: SyncDecision.deletePush,
            ok: pushed,
            error: pushed ? null : ConflictUnresolvable('tombstone 补推冲突，留待下轮'),
          ),
        );
      } catch (e) {
        report.add(
          BookSyncResult(
            bookId: entry.bookId,
            decision: SyncDecision.deletePush,
            ok: false,
            error: SyncErrorMapper.fromException(
              e,
              context: 'tombstone 补推 ${entry.bookId}',
            ),
          ),
        );
      }
    }
  }

  /// 占位书正文按需下载（docs/04 §5.4）：配额校验 → `.part` 续传 →
  /// SHA-256 校验（不一致删重来，最多 2 次）→ 转正落盘。
  Future<void> downloadContent(String bookId) async {
    final snap = await _library.book(bookId);
    final meta = snap?.meta;
    if (meta == null) {
      throw StateError('本地书库不存在该书，无法下载正文：$bookId');
    }
    final format = meta.book.format;
    final target = await _library.contentTargetPath(bookId, format: format);
    final part = await _library.contentPartPath(bookId, format: format);
    await _transfer.downloadToFile(
      bookId,
      targetPath: target,
      partPath: part,
      expectedHash: meta.book.contentHash,
      expectedSize: meta.book.sizeBytes,
    );
    // 队列已完成校验与 .part → target 原子转正；这里仅登记本地路径。
    await _library.commitContentFile(bookId, target);
  }

  /// tombstone GC（docs/04 §7.3）。
  ///
  /// - 30 天：tombstone 不再参与合并决策——合并始终走 meta 的 rev 链，引擎无需
  ///   查账本，该期限只约束上层（游离文件重关联窗口）对账本时间戳的消费；
  /// - 90 天：云端只删除 `deletedAt > 90 天` 的 tombstone meta 文件（不碰正文），
  ///   本地 `deleted_books` 账本随后同步清理。
  ///
  /// 云端 GC 由本地账本驱动而非清单摘要：`RemoteMetaStub.deleted` 在 WebDAV
  /// 的 PROPFIND 清单阶段不可知（恒 false），正确性以账本 ∩ 清单 + 逐本读
  /// meta 确认为准（两种后端行为一致）。
  Future<GcReport> gcTombstones() async {
    final errors = <SyncError>[];
    var localPurged = 0;
    var cloudDeleted = 0;
    final now = _now();

    try {
      final listing = await _adapter.listMetas();
      final ledger = await _store.tombstoneLedger();
      final cutoff = now.subtract(const Duration(days: 90));
      for (final entry in ledger) {
        if (!listing.stubs.containsKey(entry.bookId)) continue; // 云端已无 meta
        try {
          final meta = await _adapter.getMeta(entry.bookId);
          final deletedAt = meta?.deletedAt;
          if (meta != null &&
              meta.isTombstone &&
              deletedAt != null &&
              deletedAt.isBefore(cutoff)) {
            await _adapter.deleteMeta(entry.bookId);
            cloudDeleted++;
          }
        } catch (e) {
          errors.add(
            SyncErrorMapper.fromException(e, context: '云端 GC ${entry.bookId}'),
          );
        }
      }
      // 云端 GC 之后同步清理本地账本（docs/04 §7.3"本地 deleted_books 同步清理"）。
      localPurged = await _store.purgeTombstones(olderThan: cutoff);
    } catch (e) {
      errors.add(SyncErrorMapper.fromException(e, context: 'tombstone GC'));
    }

    return GcReport(
      localPurged: localPurged,
      cloudDeleted: cloudDeleted,
      errors: errors,
    );
  }

  // ── 五阶段状态机 ──────────────────────────────────────────────────────

  Future<SyncReport> _runFullSync() async {
    final report = SyncReport(startedAt: _now());
    void listener(TransferDirection dir, int bytes) {
      if (dir == TransferDirection.download) {
        report.bytesDown += bytes;
      } else {
        report.bytesUp += bytes;
      }
    }

    _transfer.addBytesListener(listener);
    try {
      // 阶段 0：首次连接确保云端布局（幂等，docs/04 §5.2）。
      await _ensureLayout();
      final id = await _identity();

      // ── 阶段 1 PullListing ──
      final cursor = await _store.cursorSnapshot(backendKey);
      final listing = await _adapter.listMetas(cursor: cursor.changesCursor);

      // ── 阶段 2 前置：账本未推送 tombstone 补推（离线删除收敛，§7.1）──
      // 必须先于 Diff：推送成功会更新 sync_state（baseRev/公共祖先），
      // Diff 依据它判定；若放在 Diff 后，删除端会把已删书误判为
      // "云端新书"（row 5）而拉回复活。
      await _pushPendingTombstones(listing, report, id);

      // ── 阶段 2 Diff ──
      final snapshots = await _library.listBooks();
      final states = {
        for (final s in await _store.allSyncStates(backendKey)) s.bookId: s,
      };
      final plan = _differ.diff(
        local: snapshots,
        remote: listing,
        syncStates: states,
      );
      report.decisions.addAll(plan.decisions);
      for (final e in plan.entries) {
        switch (e.decision) {
          case SyncDecision.inSync:
          case SyncDecision.cloudTombstoneNoLocal:
          case SyncDecision.cloudMissing:
            report.add(
              BookSyncResult(bookId: e.bookId, decision: e.decision, ok: true),
            );
          case SyncDecision.pullRemote:
          case SyncDecision.pushLocal:
          case SyncDecision.conflictMerge:
          case SyncDecision.newFromCloud:
          case SyncDecision.localNewPush:
          case SyncDecision.deletePush:
            break; // 由后续阶段记录
        }
      }
      for (final e in plan.entries) {
        if (e.decision != SyncDecision.cloudMissing) continue;
        try {
          await _library.markCloudMissing(e.bookId);
        } catch (err) {
          report.add(
            BookSyncResult(
              bookId: e.bookId,
              decision: e.decision,
              ok: false,
              error: SyncErrorMapper.fromException(err, context: '标记云端缺失'),
            ),
          );
        }
      }

      // ── 阶段 3 PullMetas（并发 2；If-None-Match 304 跳过）──
      final remoteMetas = <String, BookMeta>{};
      final corruptIds = <String>{};
      // FR-410 接收端：拉到的 meta contentHash ≠ 本地行 → 正文被他端替换，
      // 本地旧正文需重新下载覆盖（非损坏，docs/05 §6 不变式 3 出口）。
      final replacedContentIds = <String>{};
      await Future.wait([
        for (final e in plan.pullNeeded)
          _pullSlots.run(
            () => _pullOne(
              e,
              states,
              remoteMetas,
              corruptIds,
              report,
              replacedContentIds,
            ),
          ),
      ]);
      report.pullPeakConcurrency = _pullSlots.peak;

      // ── 阶段 4 PushMetas（含 §5.3 哈希去重、§6 冲突合并）──
      final skipContentUpload = await _pushMetas(
        plan,
        listing,
        states,
        remoteMetas,
        corruptIds,
        report,
        id,
      );

      // ── 阶段 5 Transfer（正文上传；下载默认按需，见 autoDownloadContent）──
      // 清单阶段无法感知 tombstone 的后端（WebDAV）此处按拉取结果兜底：
      // 已发现远端为 tombstone 的书不再下载正文（docs/04 §7.1）。
      final tombstoneDiscovered = {
        for (final e in remoteMetas.entries)
          if (e.value.isTombstone) e.key,
      };
      await _transferContents(
        plan,
        skipContentUpload,
        report,
        tombstoneDiscovered,
        replacedContentIds,
      );

      // ── 落游标 ──
      await _store.saveCursorSnapshot(
        BackendCursorSnapshot(
          backendKey: backendKey,
          changesCursor: listing.cursor,
          metaListingEtag: cursor.metaListingEtag,
          lastFullSyncAt: _now(),
          quotaUpBytes: cursor.quotaUpBytes,
          quotaDownBytes: cursor.quotaDownBytes,
          quotaMonth: cursor.quotaMonth,
        ),
      );
    } catch (e) {
      // 阶段级失败：记录分类后回 Idle（幂等可重放，docs/04 §4）。
      // 原始异常保留在 cause 供上层脱敏日志；引擎自身不落 meta 内容。
      report.phaseError = SyncErrorMapper.fromException(e, context: '全量同步');
    } finally {
      _transfer.removeBytesListener(listener);
      report.finishedAt = _now();
    }
    return report;
  }

  /// 阶段 3：拉取单本远端 meta 并应用（conflictMerge 行只缓存，合并后再应用）。
  Future<void> _pullOne(
    SyncPlanEntry entry,
    Map<String, BookSyncStateSnapshot> states,
    Map<String, BookMeta> remoteMetas,
    Set<String> corruptIds,
    SyncReport report,
    Set<String> replacedContentIds,
  ) async {
    final bookId = entry.bookId;
    final stub = entry.remote!;
    try {
      final state = states[bookId];
      var meta = await _adapter.getMeta(bookId, ifNoneMatch: state?.remoteEtag);
      if (meta == null) {
        // 304：远端未变更 → 回退本地缓存副本（公共祖先即最新副本）。
        final cached = _parseMeta(state?.lastSyncedMetaJson);
        if (cached != null) {
          meta = cached;
          report.conditionalHits++;
        } else {
          meta = await _adapter.getMeta(bookId);
        }
      }
      if (meta == null) {
        throw BackendRequestException('远端 meta 不存在', statusCode: 404);
      }
      remoteMetas[bookId] = meta;
      // FR-410 接收端：远端直接应用（pullRemote）的 meta 携带的 contentHash
      // 与本地行不一致且本地有旧正文 → 正文被他端显式替换，旧正文待下载
      // 覆盖（正常流程，非损坏）。conflictMerge 行合并结果未定，不在拉取
      // 阶段判定；tombstone 应用即移出书库，正文保留为游离文件，不下载。
      final localSnap = entry.local;
      final localHash = localSnap?.meta?.book.contentHash;
      if (entry.decision == SyncDecision.pullRemote &&
          !meta.isTombstone &&
          localSnap != null &&
          localSnap.hasLocalContent &&
          localHash != null &&
          localHash != meta.book.contentHash) {
        replacedContentIds.add(bookId);
      }
      if (entry.decision == SyncDecision.conflictMerge) {
        return; // 等合并结果出来再应用，避免覆盖本地 dirty 行
      }
      await _applyRemote(bookId, meta, stub, report, decision: entry.decision);
    } on FormatException catch (e) {
      // meta 严格校验失败 → Corruption 跳过该书，不阻塞全库（docs/05 §6）。
      corruptIds.add(bookId);
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: entry.decision,
          ok: false,
          error: Corruption('远端 meta 解析失败，已跳过', e),
        ),
      );
    } catch (e) {
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: entry.decision,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '拉取 meta $bookId'),
        ),
      );
    }
  }

  /// 应用远端 meta：书库视图/进度覆盖；tombstone 记账并移出书库视图。
  Future<void> _applyRemote(
    String bookId,
    BookMeta meta,
    RemoteMetaStub stub,
    SyncReport report, {
    SyncDecision? decision,
  }) async {
    await _library.applyRemoteMeta(meta);
    if (meta.isTombstone) {
      await _store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: bookId,
          deletedAt: meta.deletedAt ?? _now(),
          pushed: true,
          contentHash: meta.book.contentHash,
        ),
      );
    }
    await _store.saveSyncState(
      BookSyncStateSnapshot(
        bookId: bookId,
        backendKey: backendKey,
        baseRev: meta.rev,
        remoteEtag: stub.etag,
        lastSyncedMetaJson: meta.toJsonString(),
        lastSyncedAt: _now(),
      ),
    );
    report.add(BookSyncResult(bookId: bookId, decision: decision, ok: true));
  }

  /// 阶段 4：哈希去重 + 逐本推送。返回"无需/不可上传正文"的 bookId 集合。
  Future<Set<String>> _pushMetas(
    SyncPlan plan,
    MetaListing listing,
    Map<String, BookSyncStateSnapshot> states,
    Map<String, BookMeta> remoteMetas,
    Set<String> corruptIds,
    SyncReport report,
    ({String deviceId, String deviceName}) identity,
  ) async {
    final skipContentUpload = <String>{};
    final dedupHandled = <String>{};
    final localNew = plan.entries
        .where((e) => e.decision == SyncDecision.localNewPush)
        .toList();

    // §5.3 哈希去重：本地新书推送前查云端同 contentHash。
    if (localNew.isNotEmpty) {
      final hashIndex = await _buildRemoteHashIndex(
        listing,
        states,
        remoteMetas,
      );
      for (final e in localNew) {
        await _dedupNewBook(
          e,
          hashIndex,
          listing,
          report,
          identity,
          skipContentUpload,
          dedupHandled,
        );
      }
    }

    for (final e in plan.pushNeeded) {
      if (e.decision == SyncDecision.localNewPush) {
        if (dedupHandled.contains(e.bookId)) continue; // 去重路径已完成 meta 推送
        await _pushNewBook(e, report, identity, skipContentUpload);
        continue;
      }
      // conflictMerge 且远端 meta 拉取失败/损坏 → 跳过（错误已记录）。
      if (e.decision == SyncDecision.conflictMerge &&
          !remoteMetas.containsKey(e.bookId)) {
        continue;
      }
      await _pushMetaForBook(
        bookId: e.bookId,
        report: report,
        decision: e.decision,
        deviceId: identity.deviceId,
        deviceName: identity.deviceName,
        prePulledRemote: e.decision == SyncDecision.conflictMerge
            ? remoteMetas[e.bookId]
            : null,
      );
      if (corruptIds.contains(e.bookId)) skipContentUpload.add(e.bookId);
    }
    return skipContentUpload;
  }

  /// 单本推送核心（写前 expectedRev=baseRev；RevConflict → 合并 → 重试恰一次）。
  Future<void> _pushMetaForBook({
    required String bookId,
    required SyncReport report,
    required SyncDecision decision,
    required String deviceId,
    required String deviceName,
    BookMeta? prePulledRemote,
  }) async {
    try {
      final state = await _store.syncState(bookId, backendKey);
      final baseRev = state?.baseRev ?? 0;
      final ancestor = _parseMeta(state?.lastSyncedMetaJson);

      var local = await _buildLocal(bookId, baseRev, deviceId, deviceName);
      var expected = baseRev;
      // conflictMerge：预拉了远端 → 先合并再推（写即带新 rev）。
      if (prePulledRemote != null) {
        local = await _mergeAndBump(
          bookId,
          local,
          prePulledRemote,
          ancestor,
          deviceId,
          deviceName,
        );
        expected = prePulledRemote.rev;
      }
      try {
        await _adapter.putMeta(local, expectedRev: expected);
      } on RevConflict catch (conflict) {
        // 拉远端 → 合并 → 以远端当前 rev 重试恰一次（docs/04 §6.1/§8.4）。
        final remote = conflict.remoteMeta ?? await _adapter.getMeta(bookId);
        final BookMeta merged;
        final int retryExpected;
        if (remote == null) {
          merged = local; // 远端 meta 消失：按新建重试一次
          retryExpected = 0;
        } else {
          merged = await _mergeAndBump(
            bookId,
            local,
            remote,
            ancestor,
            deviceId,
            deviceName,
          );
          retryExpected = remote.rev;
        }
        try {
          await _adapter.putMeta(merged, expectedRev: retryExpected);
          local = merged;
        } on RevConflict catch (again) {
          throw ConflictUnresolvable('合并后重试仍冲突：$bookId', again);
        }
      }
      await _store.saveSyncState(
        BookSyncStateSnapshot(
          bookId: bookId,
          backendKey: backendKey,
          baseRev: local.rev,
          lastSyncedMetaJson: local.toJsonString(),
          lastSyncedAt: _now(),
        ),
      );
      // 合并结果应用回本地视图（进度收敛、dirty 清零）。
      await _library.applyRemoteMeta(local);
      report.add(BookSyncResult(bookId: bookId, decision: decision, ok: true));
    } catch (e) {
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: decision,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '推送 meta $bookId'),
        ),
      );
    }
  }

  /// 本端新书上架：推 meta（expectedRev=0），正文由阶段 5 上传。
  Future<void> _pushNewBook(
    SyncPlanEntry entry,
    SyncReport report,
    ({String deviceId, String deviceName}) identity,
    Set<String> skipContentUpload,
  ) async {
    final bookId = entry.bookId;
    try {
      final meta = await _buildLocal(
        bookId,
        0,
        identity.deviceId,
        identity.deviceName,
      );
      await _adapter.putMeta(meta, expectedRev: 0);
      await _store.saveSyncState(
        BookSyncStateSnapshot(
          bookId: bookId,
          backendKey: backendKey,
          baseRev: meta.rev,
          lastSyncedMetaJson: meta.toJsonString(),
          lastSyncedAt: _now(),
        ),
      );
      await _library.applyRemoteMeta(meta);
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: SyncDecision.localNewPush,
          ok: true,
        ),
      );
    } catch (e) {
      skipContentUpload.add(bookId);
      report.add(
        BookSyncResult(
          bookId: bookId,
          decision: SyncDecision.localNewPush,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '上架新书 $bookId'),
        ),
      );
    }
  }

  /// §5.3 哈希去重（docs/05 §4.3）：同 contentHash 全局去重，
  /// bookId 取两端字典序较小者，另一端写 `dedupOf` tombstone。
  ///
  /// [dedupHandled]：去重路径已完成 meta 推送的书（通用推送循环跳过）；
  /// [skipContentUpload]：无需/不可再上传正文的书。
  Future<void> _dedupNewBook(
    SyncPlanEntry entry,
    Map<String, BookMeta> hashIndex,
    MetaListing listing,
    SyncReport report,
    ({String deviceId, String deviceName}) identity,
    Set<String> skipContentUpload,
    Set<String> dedupHandled,
  ) async {
    final localId = entry.bookId;
    final snap = entry.local;
    final localMeta = snap?.meta;
    final localHash = localMeta?.book.contentHash;
    if (localMeta == null || localHash == null) return; // 无法比对 → 正常上架

    final matches = <MapEntry<String, BookMeta>>[
      for (final kv in hashIndex.entries)
        if (!kv.value.isTombstone &&
            kv.key != localId &&
            kv.value.book.contentHash == localHash)
          kv,
    ];
    if (matches.isEmpty) return; // 云端无同 hash 书 → 正常上架

    // 竞态出现多本同 hash：保留字典序最小 bookId（docs/05 §4.3.3）。
    matches.sort((a, b) => a.key.compareTo(b.key));
    final cloudId = matches.first.key;
    final cloudMeta = matches.first.value;
    final keepLocal = localId.compareTo(cloudId) <= 0;
    try {
      if (!keepLocal) {
        // 云端 bookId 更小 → 本地条目并入云端书，本端 bookId 写 dedupOf tombstone。
        await _library.adoptCloudBook(
          localBookId: localId,
          cloudBookId: cloudId,
          cloudMeta: cloudMeta,
        );
        final rev = await _store.nextRev(localId, atLeast: 1);
        final tomb = _makeTombstone(
          localMeta,
          rev: rev,
          deletedAt: _now(),
          deviceId: identity.deviceId,
          deviceName: identity.deviceName,
          dedupOf: cloudId,
        );
        await _adapter.putTombstone(tomb, expectedRev: 0);
        await _store.recordTombstone(
          TombstoneLedgerEntry(
            bookId: localId,
            deletedAt: _now(),
            pushed: true,
            contentHash: localHash,
          ),
        );
        await _store.saveSyncState(
          BookSyncStateSnapshot(
            bookId: localId,
            backendKey: backendKey,
            baseRev: tomb.rev,
            lastSyncedMetaJson: tomb.toJsonString(),
            lastSyncedAt: _now(),
          ),
        );
        await _store.saveSyncState(
          BookSyncStateSnapshot(
            bookId: cloudId,
            backendKey: backendKey,
            baseRev: cloudMeta.rev,
            remoteEtag: listing.stubs[cloudId]?.etag,
            lastSyncedMetaJson: cloudMeta.toJsonString(),
            lastSyncedAt: _now(),
          ),
        );
        skipContentUpload.add(localId); // 并入云端书：正文无需上传
      } else {
        // 本地 bookId 更小 → 保留本地链正常上架，云端书覆盖为 dedupOf tombstone。
        // 正文仍由阶段 5 上传（needsUpload 不含此书时才跳过）。
        final meta = await _buildLocal(
          localId,
          0,
          identity.deviceId,
          identity.deviceName,
        );
        await _adapter.putMeta(meta, expectedRev: 0);
        await _store.saveSyncState(
          BookSyncStateSnapshot(
            bookId: localId,
            backendKey: backendKey,
            baseRev: meta.rev,
            lastSyncedMetaJson: meta.toJsonString(),
            lastSyncedAt: _now(),
          ),
        );
        await _library.applyRemoteMeta(meta);
        final tomb = _makeTombstone(
          cloudMeta,
          rev: cloudMeta.rev + 1,
          deletedAt: _now(),
          deviceId: identity.deviceId,
          deviceName: identity.deviceName,
          dedupOf: localId,
        );
        await _adapter.putTombstone(tomb, expectedRev: cloudMeta.rev);
      }
      report.add(
        BookSyncResult(
          bookId: localId,
          decision: SyncDecision.localNewPush,
          ok: true,
        ),
      );
    } catch (e) {
      skipContentUpload.add(localId);
      report.add(
        BookSyncResult(
          bookId: localId,
          decision: SyncDecision.localNewPush,
          ok: false,
          error: SyncErrorMapper.fromException(e, context: '哈希去重 $localId'),
        ),
      );
    } finally {
      dedupHandled.add(localId); // 无论成败，通用推送循环不再重复处理
    }
  }

  /// 云端 contentHash → bookId 索引（去重查重用）。
  /// 数据源：本轮已拉取的 meta + 本地缓存的公共祖先副本，缺失时才逐本拉取。
  Future<Map<String, BookMeta>> _buildRemoteHashIndex(
    MetaListing listing,
    Map<String, BookSyncStateSnapshot> states,
    Map<String, BookMeta> remoteMetas,
  ) async {
    final index = <String, BookMeta>{};
    for (final stub in listing.stubs.values) {
      if (stub.deleted) continue;
      final known =
          remoteMetas[stub.bookId] ??
          _parseMeta(states[stub.bookId]?.lastSyncedMetaJson);
      if (known != null) {
        if (!known.isTombstone) index[stub.bookId] = known;
        continue;
      }
      try {
        final meta = await _adapter.getMeta(stub.bookId);
        if (meta != null && !meta.isTombstone) index[stub.bookId] = meta;
      } on FormatException {
        // 解析失败的 meta 不参与去重（该书同步时会被标 Corruption）。
      }
      // 其他拉取失败尽力忽略：去重是优化，不阻塞上架。
    }
    return index;
  }

  /// 阶段 5：正文上传（新书上架）；下载默认按需（打开占位书触发）。
  ///
  /// [replacedContentIds]：FR-410 接收端检测出的"正文被他端替换"的书
  /// （meta hash ≠ 本地旧文件 hash），随占位书一同走自动下载覆盖。
  Future<void> _transferContents(
    SyncPlan plan,
    Set<String> skipContentUpload,
    SyncReport report, [
    Set<String> skipDownload = const {},
    Set<String> replacedContentIds = const {},
  ]) async {
    for (final need in plan.needsUpload) {
      if (skipContentUpload.contains(need.bookId)) continue;
      try {
        final path = await _library.localContentPath(need.bookId);
        if (path == null || need.contentHash == null) {
          throw Corruption('本地正文缺失，无法上架（${need.bookId}）');
        }
        await _transfer.uploadFile(
          need.bookId,
          filePath: path,
          contentHash: need.contentHash!,
        );
      } catch (e) {
        report.add(
          BookSyncResult(
            bookId: need.bookId,
            decision: SyncDecision.localNewPush,
            ok: false,
            error: SyncErrorMapper.fromException(
              e,
              context: '上传正文 ${need.bookId}',
            ),
          ),
        );
      }
    }
    if (autoDownloadContent) {
      final downloaded = <String>{};
      for (final need in plan.needsDownload) {
        if (skipDownload.contains(need.bookId)) continue;
        try {
          await downloadContent(need.bookId);
          downloaded.add(need.bookId);
        } catch (e) {
          report.add(
            BookSyncResult(
              bookId: need.bookId,
              decision: SyncDecision.newFromCloud,
              ok: false,
              error: SyncErrorMapper.fromException(
                e,
                context: '下载正文 ${need.bookId}',
              ),
            ),
          );
        }
      }
      // FR-410 接收端：远端正文被替换 → 正常下载覆盖本地旧文件
      // （校验用应用后的 meta hash，机制同 §5.4 按需下载）。
      for (final bookId in replacedContentIds) {
        if (skipDownload.contains(bookId) || downloaded.contains(bookId)) {
          continue;
        }
        try {
          await downloadContent(bookId);
        } catch (e) {
          report.add(
            BookSyncResult(
              bookId: bookId,
              decision: SyncDecision.pullRemote,
              ok: false,
              error: SyncErrorMapper.fromException(
                e,
                context: '下载替换正文 $bookId',
              ),
            ),
          );
        }
      }
    }
  }

  // ── 内部工具 ──────────────────────────────────────────────────────────

  Future<void> _ensureLayout() async {
    if (_layoutEnsured) return;
    // 每个引擎实例的首次全量都确保布局（幂等，docs/04 §5.2 步骤 1）。
    // cursor.lastFullSyncAt 只证明"本机同步过"，不证明"当前后端还是当年那
    // 台"——换账号/换服务器后经 resetEngine 重建的引擎（同 store）必须在
    // 新后端上重建 library.json/meta/，否则 meta 推送因父目录缺失而 409。
    // ensureLayout 幂等且轻量（3 次 PROPFIND + 1 次 GET），无需跨实例记忆。
    await _adapter.ensureLayout();
    _layoutEnsured = true;
  }

  Future<BookMeta> _buildLocal(
    String bookId,
    int baseRev,
    String deviceId,
    String deviceName,
  ) async {
    final rev = await _store.nextRev(bookId, atLeast: baseRev + 1);
    return _library.buildLocalMeta(
      bookId,
      rev: rev,
      deviceId: deviceId,
      deviceName: deviceName,
      now: _now(),
    );
  }

  /// 合并并把本地 rev 计数器抬到合并结果水位（只增不减，docs/05 §6 不变式 1）。
  Future<BookMeta> _mergeAndBump(
    String bookId,
    BookMeta local,
    BookMeta remote,
    BookMeta? ancestor,
    String deviceId,
    String deviceName,
  ) async {
    var merged = _resolver.merge(
      local: local,
      remote: remote,
      ancestor: ancestor,
      deviceId: deviceId,
      deviceName: deviceName,
      now: _now(),
    );
    final rev = await _store.nextRev(bookId, atLeast: merged.rev);
    if (rev != merged.rev) merged = _withRev(merged, rev);
    return merged;
  }

  BookMeta? _parseMeta(String? json) {
    if (json == null) return null;
    try {
      return BookMeta.fromJsonString(json);
    } on FormatException {
      return null;
    }
  }

  Future<T> _withLock<T>(Future<T> Function() action) {
    final prev = _lock ?? Future<void>.value();
    final completer = Completer<void>();
    _lock = completer.future;
    return prev.then((_) => action()).whenComplete(() {
      completer.complete();
    });
  }

  static BookMeta _withRev(BookMeta meta, int rev) => BookMeta(
    schemaVersion: meta.schemaVersion,
    bookId: meta.bookId,
    rev: rev,
    deviceId: meta.deviceId,
    deviceName: meta.deviceName,
    createdAt: meta.createdAt,
    updatedAt: meta.updatedAt,
    deleted: meta.deleted,
    deletedAt: meta.deletedAt,
    dedupOf: meta.dedupOf,
    book: meta.book,
    progress: meta.progress,
    reading: meta.reading,
    annotations: meta.annotations,
    extra: meta.extra,
  );

  static BookMeta _makeTombstone(
    BookMeta base, {
    required int rev,
    required DateTime deletedAt,
    required String deviceId,
    required String deviceName,
    String? dedupOf,
  }) => BookMeta(
    schemaVersion: base.schemaVersion,
    bookId: base.bookId,
    rev: rev,
    deviceId: deviceId,
    deviceName: deviceName,
    createdAt: base.createdAt,
    updatedAt: deletedAt,
    deleted: true,
    deletedAt: deletedAt,
    dedupOf: dedupOf ?? base.dedupOf,
    book: base.book,
    progress: base.progress,
    reading: base.reading,
    annotations: base.annotations,
    extra: base.extra,
  );
}
