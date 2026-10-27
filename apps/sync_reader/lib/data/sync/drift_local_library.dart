/// sync_core `LocalLibrary` 的 drift 桥接（books/progress 表 + [BookFileStore]）。
///
/// 与云端 JSON 的字段映射以 docs/05 §5"云端 JSON ↔ 本地表映射"为准：
/// - `book.*` → books 表；`progress.*` → progress 表（dirty=0 表示与云端一致）；
/// - `reading.*` → books.total_seconds / last_read_at；
/// - rev/baseRev 不落书表（以 sync_state 为准，由 [DriftSyncStore] 持有），
///   快照里的 baseRev 视图从 sync_state 表读出供 Diff 兜底。
///
/// 删除语义（docs/04 §7.1.2）：应用 tombstone = 记 deleted_books 已确认 +
/// 移出书库视图（删除 books 行，进度级联清除）；**正文文件保留在原处**
/// （转游离，M4 提供游离面板 UI；保留原路径以便未来按 bookId/hash 重关联）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:sync_core/sync_core.dart';

import '../db/app_database.dart';
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
    return [
      for (final book in rows)
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
        // 移出书库视图：books 行删除，progress 级联清除；正文文件保留（游离）。
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
          ),
        );

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

  // ── 内部工具 ──────────────────────────────────────────────────────────

  BooksDao get _booksDao => _db.booksDao;
  ProgressDao get _progressDao => _db.progressDao;

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
    return LocalBookSnapshot(
      bookId: book.bookId,
      meta: _skeletonMeta(book, progress),
      exists: true,
      dirty: progress?.dirty ?? false,
      hasBaseRev: hasBaseRev,
      baseRev: state?.baseRev ?? 0,
      hasLocalContent: (book.localPath ?? '').isNotEmpty,
    );
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
    );
  }
}
