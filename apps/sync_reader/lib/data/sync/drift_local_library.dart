/// sync_core `LocalLibrary` 的 drift 桥接（books/progress 表 + [BookFileStore]）。
///
/// 与云端 JSON 的字段映射以 docs/05 §5"云端 JSON ↔ 本地表映射"为准：
/// - `book.*` → books 表；`progress.*` → progress 表（dirty=0 表示与云端一致）；
/// - `reading.*` → books.total_seconds / last_read_at；
/// - rev/baseRev 不落书表（以 sync_state 为准，由 [DriftSyncStore] 持有），
///   快照里的 baseRev 视图从 sync_state 表读出供 Diff 兜底。
///
/// 删除语义（docs/10 §4.7b，2026-11-18 变更）：
/// - **本端删除** = 删正文/封面文件 + **移出书库**（`books` 行删除）+ 写
///   `deleted_books` 墓碑；带墓碑的书**不参与 diff**（否则会被当正常书推回
///   云端，与刚推上去的 tombstone 打架）；
/// - **收到远端墓碑**：本端已有墓碑（= 本端自己删的）→ 幂等，不覆盖已有的
///   deletedAt/pushed/contentHash（否则会把待推墓碑的记账抹掉）；本端未发起
///   的（其它设备删的）→ 沿用 docs/04 §7.1.2 既有行为：删 books 行（正文
///   文件保留为游离文件）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:sync_core/sync_core.dart';

import '../db/app_database.dart';
import '../db/daos/book_groups_dao.dart';
import '../db/daos/books_dao.dart';
import '../db/daos/progress_dao.dart';
import '../files/book_file_store.dart';

/// [LocalLibrary] 的 drift 实现。
final class DriftLocalLibrary implements LocalLibrary {
  /// 构造。[fileStore] 提供正文/封面路径布局（与导入共用同一布局）。
  DriftLocalLibrary({
    required this._db,
    required this._fileStore,
    this.backendKey = 'webdav',
  });

  final AppDatabase _db;
  final Future<BookFileStore> _fileStore;

  /// sync_state 兜底查询使用的后端键（与 [DriftSyncStore] 一致，FR-405 同期仅一个后端）。
  final String backendKey;

  /// "云端缺失"标记（docs/04 §5.1 第 7b 行）。
  ///
  /// 内存态即可：每轮全量同步 Diff 都会重新发出该标记（本地有 baseRev 而
  /// 远端无 meta），重启后由下一次全量同步（启动后 2s）自动恢复；不落库
  /// 是因为 books 表不允许加列（docs/05 §5 DDL 为同步语义的一部分）。
  final Set<String> cloudMissingMarks = {};

  // ── LocalLibrary：快照 ────────────────────────────────────────────────

  @override
  Future<List<LocalBookSnapshot>> listBooks() async {
    final rows = await _db.select(_db.books).get();
    final progressRows = {
      for (final p in await _db.select(_db.progress).get()) p.bookId: p,
    };
    final states = await _statesByBookId();
    // 排除两类书（docs/10 §4.7b / §4.7c）：
    // 1. 有墓碑的书（本地已删除）——本地删除已移出书库（无 `books` 行），
    //    这里再排除一次是兜底：防止"墓碑已记账但行仍在"的竞态下被引擎当
    //    正常书推回云端，与刚推上去的 tombstone 打架；
    // 2. 仅本地的书（local_only_books）——它们永不进 diff，既不推 meta
    //    也不传正文（用户明确选择"不上传"）。
    final tombstoned = await _tombstonedBookIds();
    final localOnly = await _localOnlyBookIds();
    return [
      for (final book in rows)
        if (!tombstoned.contains(book.bookId) &&
            !localOnly.contains(book.bookId))
          _snapshotFor(book, progressRows[book.bookId], states[book.bookId]),
    ];
  }

  @override
  Future<LocalBookSnapshot?> book(String bookId) async {
    final row = await _booksDao.getById(bookId);
    if (row == null) return null;
    final progress = await _progressDao.getByBookId(bookId);
    final state = (await _statesByBookId())[bookId];
    return _snapshotFor(row, progress, state);
  }

  // ── LocalLibrary：远端 meta 应用 ──────────────────────────────────────

  @override
  Future<void> applyRemoteMeta(BookMeta meta) async {
    if (meta.isTombstone) {
      await _db.transaction(() async {
        // 记 tombstone 已确认（docs/04 §7.1.2：sync_state 记录删除已确认）。
        // 本端已有该书的墓碑 ⇒ 本端自己删的 → **不覆盖**已有的
        // deletedAt / pushed / contentHash：`pushed=false` 是"待推墓碑"的
        // 记账，覆盖成 true 会让离线删除的墓碑永远推不出去。
        final existing = await (_db.select(
          _db.deletedBooks,
        )..where((d) => d.bookId.equals(meta.bookId))).getSingleOrNull();
        if (existing == null) {
          await _db
              .into(_db.deletedBooks)
              .insertOnConflictUpdate(
                DeletedBooksCompanion(
                  bookId: Value(meta.bookId),
                  deletedAt: Value(
                    (meta.deletedAt ?? DateTime.now()).millisecondsSinceEpoch,
                  ),
                  pushed: const Value(true),
                  contentHash: Value(meta.book.contentHash),
                ),
              );
        }
        // 移出书库（books 行删除，progress 级联清除）——本端自己删的与
        // 其它设备删的同款处理：删除即移出书库（docs/10 §4.7b）。
        // 本端自己删的通常已无行（本地删除时删掉了），这里是幂等兜底；
        // 它真正兜住的是"墓碑还没推上去、书却被别的设备改活"的竞态：
        // 那次拉活会重建 books 行（占位书），墓碑回来时必须把它收走。
        // 本地正文文件保留（游离，docs/04 §7.1.2 不变）。
        await (_db.delete(
          _db.books,
        )..where((b) => b.bookId.equals(meta.bookId))).go();
      });
      return;
    }

    final existing = await _booksDao.getById(meta.bookId);
    // 正文：本地已有且文件仍在 → 保留路径；否则占位（docs/04 §5.1 第 2 行）。
    final prevPath = existing?.localPath;
    final localPath =
        (prevPath != null &&
            prevPath.isNotEmpty &&
            await File(prevPath).exists())
        ? prevPath
        : null;

    // 分组归属（FR-107，docs/05 §2.2）：远端分组本地不存在 → 视为未分组
    // （不得写入悬空外键；分组随后到达时由其 meta 应用补回）。
    final remoteGroupId = await _resolveRemoteGroupId(meta.groupId);

    await _db
        .into(_db.books)
        .insertOnConflictUpdate(
          Book(
            bookId: meta.bookId,
            title: meta.book.title,
            author: meta.book.author,
            format: meta.book.format,
            fileName: meta.book.fileName,
            localPath: localPath,
            contentHash: meta.book.contentHash,
            sizeBytes: meta.book.sizeBytes,
            coverPath: existing?.coverPath,
            tocFingerprint: meta.book.tocFingerprint,
            addedAt: existing?.addedAt ?? meta.createdAt.millisecondsSinceEpoch,
            lastReadAt: meta.reading.lastReadAt.millisecondsSinceEpoch,
            totalSeconds: meta.reading.totalSeconds,
            groupId: remoteGroupId,
          ),
        );

    // 分组归属**显式落列**：drift 的 data class upsert 会忽略 null 值
    // （toColumns(nullToAbsent=true)）→ "远端未分组"必须单独清空本地归属，
    // 否则旧的 group_id 会残留（books.group_id 进 meta，docs/05 §2.2）。
    await (_db.update(_db.books)..where((b) => b.bookId.equals(meta.bookId)))
        .write(BooksCompanion(groupId: Value(remoteGroupId)));

    // 进度：远端无进度 → 清除本地进度行；有 → 覆盖（dirty=false，与云端一致）。
    final progress = meta.progress;
    if (progress == null) {
      await (_db.delete(
        _db.progress,
      )..where((p) => p.bookId.equals(meta.bookId))).go();
    } else {
      await _db
          .into(_db.progress)
          .insertOnConflictUpdate(
            ProgressCompanion(
              bookId: Value(meta.bookId),
              locatorJson: Value(jsonEncode(progress.locator.toJson())),
              percent: Value(progress.percent),
              updatedAt: Value(progress.updatedAt.millisecondsSinceEpoch),
              dirty: const Value(false),
            ),
          );
    }
  }

  @override
  Future<void> markCloudMissing(String bookId) async {
    cloudMissingMarks.add(bookId);
  }

  @override
  Future<void> adoptCloudBook({
    required String localBookId,
    required String cloudBookId,
    required BookMeta cloudMeta,
  }) async {
    final local = await _booksDao.getById(localBookId);
    final localProgress = await _progressDao.getByBookId(localBookId);

    // 正文文件挪到云端 bookId 名下（docs/04 §5.3：本地条目并入云端书）。
    String? newPath;
    final prevPath = local?.localPath;
    if (local != null && prevPath != null && prevPath.isNotEmpty) {
      final source = File(prevPath);
      if (await source.exists()) {
        final store = await _fileStore;
        newPath = store.resolveBookPath(cloudBookId, local.format);
        final target = File(newPath);
        await target.parent.create(recursive: true);
        if (await target.exists()) await target.delete();
        await source.rename(newPath);
      }
    }

    // 进度 LWW：本地 progress 行 vs 云端 meta.progress，updatedAt 新者胜。
    final localReading = localProgress == null
        ? null
        : ReadingProgress(
            locator: Locator.fromJsonString(localProgress.locatorJson),
            percent: localProgress.percent,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(
              localProgress.updatedAt,
            ),
          );
    final remoteProgress = cloudMeta.progress;
    final ReadingProgress? progress;
    if (localReading == null) {
      progress = remoteProgress;
    } else if (remoteProgress == null) {
      progress = localReading;
    } else {
      progress = localReading.updatedAt.isAfter(remoteProgress.updatedAt)
          ? localReading
          : remoteProgress;
    }
    final lastReadAtCandidates = [
      if (local?.lastReadAt != null) local!.lastReadAt!,
      cloudMeta.reading.lastReadAt.millisecondsSinceEpoch,
    ];

    await _db.transaction(() async {
      // 删除本地 bookId 行（progress 级联清除）。
      await (_db.delete(
        _db.books,
      )..where((b) => b.bookId.equals(localBookId))).go();
      final cloudExisting = await _booksDao.getById(cloudBookId);
      await _db
          .into(_db.books)
          .insertOnConflictUpdate(
            Book(
              bookId: cloudBookId,
              title: cloudMeta.book.title,
              author: cloudMeta.book.author,
              format: cloudMeta.book.format,
              fileName: cloudMeta.book.fileName,
              localPath: newPath ?? cloudExisting?.localPath,
              contentHash: cloudMeta.book.contentHash,
              sizeBytes: cloudMeta.book.sizeBytes,
              coverPath: cloudExisting?.coverPath,
              tocFingerprint: cloudMeta.book.tocFingerprint,
              addedAt:
                  local?.addedAt ?? cloudMeta.createdAt.millisecondsSinceEpoch,
              lastReadAt: lastReadAtCandidates.reduce(math.max),
              totalSeconds:
                  (local?.totalSeconds ?? 0) + cloudMeta.reading.totalSeconds,
            ),
          );
      if (progress == null) {
        await (_db.delete(
          _db.progress,
        )..where((p) => p.bookId.equals(cloudBookId))).go();
      } else {
        await _db
            .into(_db.progress)
            .insertOnConflictUpdate(
              ProgressCompanion(
                bookId: Value(cloudBookId),
                locatorJson: Value(jsonEncode(progress.locator.toJson())),
                percent: Value(progress.percent),
                updatedAt: Value(progress.updatedAt.millisecondsSinceEpoch),
                dirty: const Value(false),
              ),
            );
      }
    });
  }

  // ── LocalLibrary：本地 meta 组装 ──────────────────────────────────────

  @override
  Future<BookMeta> buildLocalMeta(
    String bookId, {
    required int rev,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  }) async {
    final row = await _booksDao.getById(bookId);
    if (row == null) {
      throw StateError('本地不存在该书，无法构建 meta：$bookId');
    }
    final progress = await _progressDao.getByBookId(bookId);
    return _skeletonMeta(
      row,
      progress,
      rev: rev,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  // ── LocalLibrary：正文文件路径 ────────────────────────────────────────

  @override
  Future<String?> localContentPath(String bookId) async {
    final row = await _booksDao.getById(bookId);
    final path = row?.localPath;
    if (path == null || path.isEmpty) return null;
    // 文件已被外部移除 → 视为占位（引擎据此重下/重传）。
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<String> contentTargetPath(
    String bookId, {
    required String format,
  }) async {
    final store = await _fileStore;
    return store.resolveBookPath(bookId, format);
  }

  @override
  Future<String> contentPartPath(
    String bookId, {
    required String format,
  }) async {
    final store = await _fileStore;
    return '${store.resolveBookPath(bookId, format)}.part';
  }

  @override
  Future<void> commitContentFile(String bookId, String contentFile) async {
    final row = await _booksDao.getById(bookId);
    if (row == null) throw StateError('本地不存在该书：$bookId');
    if (!await File(contentFile).exists()) {
      throw StateError('下载产物不存在：$contentFile');
    }
    await (_db.update(_db.books)..where((b) => b.bookId.equals(bookId))).write(
      BooksCompanion(localPath: Value(contentFile)),
    );
  }

  @override
  Future<void> updateBookFileInfo(
    String bookId, {
    String? fileName,
    String? contentHash,
    int? sizeBytes,
    String? format,
  }) async {
    final row = await _booksDao.getById(bookId);
    if (row == null) {
      throw StateError('本地不存在该书，无法更新文件信息：$bookId');
    }
    // 仅更新非 null 实参对应的列（FR-410：app 已把新文件落盘并重解析）。
    await (_db.update(_db.books)..where((b) => b.bookId.equals(bookId))).write(
      BooksCompanion(
        fileName: fileName == null
            ? const Value.absent()
            : Value<String>(fileName),
        contentHash: contentHash == null
            ? const Value.absent()
            : Value<String>(contentHash),
        sizeBytes: sizeBytes == null
            ? const Value.absent()
            : Value<int>(sizeBytes),
        format: format == null ? const Value.absent() : Value<String>(format),
      ),
    );
    // format 变化 → 按新扩展名重探本地正文路径（与内存参考实现一致）：
    // 新路径文件已落盘则指过去，否则置占位（引擎 replaceBookContent 会按
    // Corruption 报告，由上层流程保证先落盘）。
    if (format != null && format != row.format) {
      final store = await _fileStore;
      final newPath = store.resolveBookPath(bookId, format);
      final exists = await File(newPath).exists();
      await (_db.update(_db.books)..where((b) => b.bookId.equals(bookId)))
          .write(BooksCompanion(localPath: Value(exists ? newPath : null)));
    }
  }

  // ── LocalLibrary：分组（FR-107 云端同步，docs/05 §2.1）──────────────

  @override
  Future<List<LocalGroupSnapshot>> listGroups() async {
    final rows = await _groupsDao.allGroupsIncludingDeleted();
    final states = await _groupStatesByGroupId();
    return [
      for (final row in rows) _groupSnapshotFor(row, states[row.groupId]),
    ];
  }

  @override
  Future<LocalGroupSnapshot?> group(String groupId) async {
    final row = await _groupsDao.groupById(groupId);
    if (row == null) return null;
    final states = await _groupStatesByGroupId();
    return _groupSnapshotFor(row, states[groupId]);
  }

  @override
  Future<void> applyRemoteGroup(GroupMeta meta) async {
    if (meta.isTombstone) {
      // 分组在云端已删 → 本地移除该分组行（组内书籍由外键 ON DELETE SET NULL
      // 回到未分组，不丢书）。
      await (_db.delete(
        _db.bookGroups,
      )..where((g) => g.groupId.equals(meta.groupId))).go();
      return;
    }
    final existing = await _groupsDao.groupById(meta.groupId);
    if (existing == null) {
      await _db
          .into(_db.bookGroups)
          .insert(
            BookGroupsCompanion.insert(
              groupId: meta.groupId,
              name: meta.name,
              sortOrder: Value(meta.sortOrder),
              createdAt: meta.createdAt.millisecondsSinceEpoch,
            ),
          );
      return;
    }
    // 改名/排序以远端为准（引擎已按 LWW 定序裁决）。
    await (_db.update(
      _db.bookGroups,
    )..where((g) => g.groupId.equals(meta.groupId))).write(
      BookGroupsCompanion(
        name: Value(meta.name),
        sortOrder: Value(meta.sortOrder),
        deleted: const Value(false),
        deletedAt: const Value(null),
      ),
    );
  }

  @override
  Future<GroupMeta> buildLocalGroupMeta(
    String groupId, {
    required int rev,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  }) async {
    final row = await _groupsDao.groupById(groupId);
    if (row == null) {
      throw StateError('本地不存在该分组，无法构建 meta：$groupId');
    }
    return GroupMeta(
      schemaVersion: kGroupSchemaVersion,
      groupId: row.groupId,
      rev: rev,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      updatedAt: now,
      name: row.name,
      sortOrder: row.sortOrder,
      // 待推送形态恒为"活分组"；墓碑由引擎按删除路径显式构造。
      deleted: false,
    );
  }

  @override
  Future<void> mergeLocalGroup({
    required String fromGroupId,
    required String toGroupId,
    required String toName,
    required int toSortOrder,
  }) async {
    await _groupsDao.mergeGroup(
      fromGroupId: fromGroupId,
      toGroupId: toGroupId,
      toName: toName,
      toSortOrder: toSortOrder,
    );
  }

  /// 分组快照：dirty = 名称/排序与上次同步的副本不一致（docs/04 §5.1）。
  LocalGroupSnapshot _groupSnapshotFor(
    BookGroup row,
    GroupSyncStateRow? state,
  ) {
    final synced = _parseGroupJson(state?.lastSyncedGroupJson);
    final dirty = synced == null
        ? false
        : (synced.name != row.name || synced.sortOrder != row.sortOrder);
    return LocalGroupSnapshot(
      groupId: row.groupId,
      name: row.name,
      sortOrder: row.sortOrder,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      exists: true,
      deleted: row.deleted,
      dirty: dirty,
      hasBaseRev: state != null,
      baseRev: state?.baseRev ?? 0,
    );
  }

  /// 解析上次同步的分组副本（公共祖先；损坏时按 null 处理）。
  GroupMeta? _parseGroupJson(String? raw) {
    if (raw == null) return null;
    try {
      return GroupMeta.fromJsonString(raw);
    } on FormatException {
      return null;
    }
  }

  Future<Map<String, GroupSyncStateRow>> _groupStatesByGroupId() async {
    final rows = await (_db.select(
      _db.groupSyncState,
    )..where((s) => s.backendKey.equals(backendKey))).get();
    return {for (final row in rows) row.groupId: row};
  }

  // ── 内部工具 ──────────────────────────────────────────────────────────

  BooksDao get _booksDao => _db.booksDao;
  ProgressDao get _progressDao => _db.progressDao;
  BookGroupsDao get _groupsDao => _db.bookGroupsDao;

  /// 有墓碑的 bookId 集合（本地已删除的书；不参与 diff）。
  Future<Set<String>> _tombstonedBookIds() async {
    final rows = await _db.select(_db.deletedBooks).get();
    return rows.map((row) => row.bookId).toSet();
  }

  /// 仅本地的 bookId 集合（用户选择"不上传"的书；不参与 diff）。
  Future<Set<String>> _localOnlyBookIds() async {
    final rows = await _db.select(_db.localOnlyBooks).get();
    return rows.map((row) => row.bookId).toSet();
  }

  Future<Map<String, BookSyncState>> _statesByBookId() async {
    final rows = await (_db.select(
      _db.syncState,
    )..where((s) => s.backendKey.equals(backendKey))).get();
    return {for (final row in rows) row.bookId: row};
  }

  LocalBookSnapshot _snapshotFor(
    Book book,
    BookProgress? progress,
    BookSyncState? state,
  ) {
    final hasBaseRev = state != null;
    // 分组归属进入书籍 meta（docs/05 §2.2）→ 归属变了就是"未推送的修改"
    // （与进度 dirty 同款语义：本地 group_id ≠ 上次同步的 group_id）。
    final syncedGroupId = _parseBookMetaJson(state?.lastSyncedMetaJson)
        ?.groupId;
    final groupChanged = state != null && syncedGroupId != book.groupId;
    return LocalBookSnapshot(
      bookId: book.bookId,
      meta: _skeletonMeta(book, progress),
      exists: true,
      dirty: (progress?.dirty ?? false) || groupChanged,
      hasBaseRev: hasBaseRev,
      baseRev: state?.baseRev ?? 0,
      hasLocalContent: (book.localPath ?? '').isNotEmpty,
    );
  }

  /// 远端 groupId → 本地可用的 groupId（分组不存在则 null，避免悬空外键）。
  Future<String?> _resolveRemoteGroupId(String? groupId) async {
    if (groupId == null || groupId.isEmpty) return null;
    final row = await _groupsDao.groupById(groupId);
    return row == null ? null : groupId;
  }

  /// 解析上次同步的书籍 meta 副本（公共祖先；损坏时按 null 处理）。
  BookMeta? _parseBookMetaJson(String? raw) {
    if (raw == null) return null;
    try {
      return BookMeta.fromJsonString(raw);
    } on FormatException {
      return null;
    }
  }

  /// 本地行 → meta 骨架（推送时才定 rev/设备信息，docs/04 §2；Diff/去重用）。
  BookMeta _skeletonMeta(
    Book book,
    BookProgress? progress, {
    int? rev,
    String? deviceId = 'local',
    String? deviceName = 'local',
  }) {
    final addedAt = DateTime.fromMillisecondsSinceEpoch(book.addedAt);
    final progressUpdatedAt = progress == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(progress.updatedAt);
    final updatedAt = progressUpdatedAt ?? addedAt;
    final lastReadAt = book.lastReadAt == null
        ? updatedAt
        : DateTime.fromMillisecondsSinceEpoch(book.lastReadAt!);
    return BookMeta(
      schemaVersion: kCurrentSchemaVersion,
      bookId: book.bookId,
      rev: rev ?? 1,
      deviceId: deviceId ?? 'local',
      deviceName: deviceName ?? 'local',
      createdAt: addedAt,
      updatedAt: updatedAt,
      book: BookInfo(
        title: book.title,
        author: book.author,
        format: book.format,
        fileName: book.fileName,
        contentHash: book.contentHash,
        sizeBytes: book.sizeBytes,
        tocFingerprint: book.tocFingerprint,
      ),
      progress: progress == null
          ? null
          : ReadingProgress(
              locator: Locator.fromJsonString(progress.locatorJson),
              percent: progress.percent,
              updatedAt: progressUpdatedAt!,
            ),
      reading: ReadingStats(
        totalSeconds: book.totalSeconds,
        lastReadAt: lastReadAt,
      ),
      groupId: book.groupId,
    );
  }
}
