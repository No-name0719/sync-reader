/// sync_core `SyncStore` 的 drift 持久化桥接（docs/05 §5
/// `sync_state` / `deleted_books` / `sync_cursor` 三表；deviceId 走安全存储）。
///
/// 设计要点：
/// - **写端 rev 计数器**：以 sync_state 的 `baseRev`（per (bookId, backendKey)
///   行）作持久计数器基线，`nextRev = max(baseRev + 1, atLeast)`；合并结果的
///   rev 抬升由引擎推送成功后经 [saveSyncState] 持久化（docs/04 §2"上传成功后
///   记入 baseRev"）。按 (bookId, backendKey) 独立计数：同一时刻只启用一个后端
///   （FR-405），切换后端计数器重建不破坏"只增不减"语义；
/// - `purgeTombstones` 为**严格早于**边界（`isBefore`），与接口文档和云端 90 天
///   GC 对齐（docs/04 §7.3）；
/// - 配额计数 [addQuotaUsage]：读改写游标快照，跨自然月自动清零（docs/04 §8.3）。
library;

import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:sync_core/sync_core.dart';

import '../db/app_database.dart';
import '../secure/secure_credential_store.dart';

/// [SyncStore] 的 drift 实现。
final class DriftSyncStore implements SyncStore {
  /// 构造。[credentials] 仅用于 deviceId 的读写（安全存储，不落 SQLite）。
  DriftSyncStore({
    required this._db,
    required this._credentials,
    this.backendKey = 'webdav',
  });

  final AppDatabase _db;
  final CredentialStore _credentials;

  /// [nextRev] 使用的后端键（docs/05 §5：'webdav' | 'server:{libraryId}'）。
  final String backendKey;

  // ── SyncStore：设备 ID ────────────────────────────────────────────────

  @override
  Future<String> loadOrCreateDeviceId({
    required String Function() generate,
  }) async {
    final existing = await _credentials.read(SecureKeys.deviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = generate();
    await _credentials.save(SecureKeys.deviceId, id);
    return id;
  }

  // ── SyncStore：rev 持久计数器 ─────────────────────────────────────────

  @override
  Future<int> nextRev(String bookId, {int atLeast = 0}) async {
    final row = await _stateRow(bookId, backendKey);
    final base = row?.baseRev ?? 0;
    return math.max(base + 1, atLeast);
  }

  // ── SyncStore：同步状态 ───────────────────────────────────────────────

  @override
  Future<BookSyncStateSnapshot?> syncState(
    String bookId,
    String backendKey,
  ) async {
    final row = await _stateRow(bookId, backendKey);
    return row == null ? null : _stateSnapshot(row);
  }

  @override
  Future<void> saveSyncState(BookSyncStateSnapshot state) {
    return _db
        .into(_db.syncState)
        .insertOnConflictUpdate(
          SyncStateCompanion(
            bookId: Value(state.bookId),
            backendKey: Value(state.backendKey),
            baseRev: Value(state.baseRev),
            remoteEtag: Value(state.remoteEtag),
            lastSyncedMetaJson: Value(state.lastSyncedMetaJson),
            lastSyncedAt: Value(state.lastSyncedAt.millisecondsSinceEpoch),
          ),
        );
  }

  @override
  Future<List<BookSyncStateSnapshot>> allSyncStates(String backendKey) async {
    final rows = await (_db.select(
      _db.syncState,
    )..where((s) => s.backendKey.equals(backendKey))).get();
    return [for (final row in rows) _stateSnapshot(row)];
  }

  // ── SyncStore：tombstone 账本 ─────────────────────────────────────────

  @override
  Future<List<TombstoneLedgerEntry>> tombstoneLedger() async {
    final rows = await _db.select(_db.deletedBooks).get();
    return [
      for (final row in rows)
        TombstoneLedgerEntry(
          bookId: row.bookId,
          deletedAt: DateTime.fromMillisecondsSinceEpoch(row.deletedAt),
          pushed: row.pushed,
          contentHash: row.contentHash,
        ),
    ];
  }

  @override
  Future<void> recordTombstone(TombstoneLedgerEntry entry) {
    return _db
        .into(_db.deletedBooks)
        .insertOnConflictUpdate(
          DeletedBooksCompanion(
            bookId: Value(entry.bookId),
            deletedAt: Value(entry.deletedAt.millisecondsSinceEpoch),
            pushed: Value(entry.pushed),
            contentHash: Value(entry.contentHash),
          ),
        );
  }

  @override
  Future<void> markTombstonePushed(String bookId) {
    return (_db.update(_db.deletedBooks)..where((d) => d.bookId.equals(bookId)))
        .write(const DeletedBooksCompanion(pushed: Value(true)));
  }

  @override
  Future<int> purgeTombstones({required DateTime olderThan}) async {
    final cutoff = olderThan.millisecondsSinceEpoch;
    final doomed = await (_db.select(
      _db.deletedBooks,
    )..where((d) => d.deletedAt.isSmallerThanValue(cutoff))).get();
    if (doomed.isEmpty) return 0;
    final ids = doomed.map((d) => d.bookId).toList();
    await (_db.delete(_db.deletedBooks)..where((d) => d.bookId.isIn(ids))).go();
    return ids.length;
  }

  // ── SyncStore：游标快照 ───────────────────────────────────────────────

  @override
  Future<BackendCursorSnapshot> cursorSnapshot(String backendKey) async {
    final row = await (_db.select(
      _db.syncCursor,
    )..where((c) => c.backendKey.equals(backendKey))).getSingleOrNull();
    if (row == null) return BackendCursorSnapshot(backendKey: backendKey);
    return BackendCursorSnapshot(
      backendKey: backendKey,
      changesCursor: row.changesCursor,
      metaListingEtag: row.metaListingEtag,
      lastFullSyncAt: row.lastFullSyncAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row.lastFullSyncAt!),
      quotaUpBytes: row.quotaUpBytes,
      quotaDownBytes: row.quotaDownBytes,
      quotaMonth: row.quotaMonth,
    );
  }

  @override
  Future<void> saveCursorSnapshot(BackendCursorSnapshot snapshot) {
    return _db
        .into(_db.syncCursor)
        .insertOnConflictUpdate(
          SyncCursorCompanion(
            backendKey: Value(snapshot.backendKey),
            changesCursor: Value(snapshot.changesCursor),
            metaListingEtag: Value(snapshot.metaListingEtag),
            lastFullSyncAt: Value(
              snapshot.lastFullSyncAt?.millisecondsSinceEpoch,
            ),
            quotaUpBytes: Value(snapshot.quotaUpBytes),
            quotaDownBytes: Value(snapshot.quotaDownBytes),
            quotaMonth: Value(snapshot.quotaMonth),
          ),
        );
  }

  // ── 配额计数（docs/04 §8.3，超出 SyncStore 契约的 app 侧扩展）──────────

  /// 累加上/下行流量：读改写游标快照；[quotaMonth] ≠ 当前月时先清零再累加
  /// （跨自然月自动重置，docs/04 §8.3）。返回更新后的快照。
  Future<BackendCursorSnapshot> addQuotaUsage({
    required int upBytes,
    required int downBytes,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final month = quotaMonthOf(at);
    return _db.transaction(() async {
      final snap = await cursorSnapshot(backendKey);
      final sameMonth = snap.quotaMonth == month;
      final updated = BackendCursorSnapshot(
        backendKey: backendKey,
        changesCursor: snap.changesCursor,
        metaListingEtag: snap.metaListingEtag,
        lastFullSyncAt: snap.lastFullSyncAt,
        quotaUpBytes: (sameMonth ? snap.quotaUpBytes : 0) + upBytes,
        quotaDownBytes: (sameMonth ? snap.quotaDownBytes : 0) + downBytes,
        quotaMonth: month,
      );
      await saveCursorSnapshot(updated);
      return updated;
    });
  }

  /// 配额所属自然月标记（如 `2026-10`）。
  static String quotaMonthOf(DateTime at) =>
      '${at.year}-${at.month.toString().padLeft(2, '0')}';

  // ── 内部工具 ──────────────────────────────────────────────────────────

  Future<BookSyncState?> _stateRow(String bookId, String backendKey) {
    return (_db.select(_db.syncState)..where(
          (s) => s.bookId.equals(bookId) & s.backendKey.equals(backendKey),
        ))
        .getSingleOrNull();
  }

  BookSyncStateSnapshot _stateSnapshot(BookSyncState row) =>
      BookSyncStateSnapshot(
        bookId: row.bookId,
        backendKey: row.backendKey,
        baseRev: row.baseRev,
        remoteEtag: row.remoteEtag,
        lastSyncedMetaJson: row.lastSyncedMetaJson,
        lastSyncedAt: DateTime.fromMillisecondsSinceEpoch(row.lastSyncedAt),
      );
}
