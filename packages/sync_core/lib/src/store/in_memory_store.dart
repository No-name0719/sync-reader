import 'dart:io';

import '../diff/diff_engine.dart';
import '../model/book_meta.dart';
import '../model/group_meta.dart';
import 'local_library.dart';
import 'sync_store.dart';

/// [SyncStore] 的内存参考实现：引擎/契约测试与 app 侧测试复用；
/// drift 持久化实现由 app 侧提供（docs/05 §5）。
class InMemorySyncStore implements SyncStore {
  String? _deviceId;
  final Map<String, int> _revCounters = {};
  final Map<String, BookSyncStateSnapshot> _states = {};
  final Map<String, TombstoneLedgerEntry> _ledger = {};
  final Map<String, BackendCursorSnapshot> _cursors = {};
  final Map<String, int> _groupRevCounters = {};
  final Map<String, GroupSyncStateSnapshot> _groupStates = {};

  @override
  Future<String> loadOrCreateDeviceId({
    required String Function() generate,
  }) async {
    return _deviceId ??= generate();
  }

  @override
  Future<int> nextRev(String bookId, {int atLeast = 0}) async {
    // 计数器存"已用最大 rev"：下一个 = max(已用 + 1, atLeast)，只增不减。
    final next = _max((_revCounters[bookId] ?? 0) + 1, atLeast);
    _revCounters[bookId] = next;
    return next;
  }

  @override
  Future<BookSyncStateSnapshot?> syncState(
    String bookId,
    String backendKey,
  ) async {
    return _states['$backendKey|$bookId'];
  }

  @override
  Future<void> saveSyncState(BookSyncStateSnapshot state) async {
    _states['${state.backendKey}|${state.bookId}'] = state;
  }

  @override
  Future<List<BookSyncStateSnapshot>> allSyncStates(String backendKey) async {
    return _states.values
        .where((s) => s.backendKey == backendKey)
        .toList(growable: false);
  }

  @override
  Future<List<TombstoneLedgerEntry>> tombstoneLedger() async =>
      _ledger.values.toList(growable: false);

  @override
  Future<void> recordTombstone(TombstoneLedgerEntry entry) async {
    _ledger[entry.bookId] = entry;
  }

  @override
  Future<void> markTombstonePushed(String bookId) async {
    final old = _ledger[bookId];
    if (old != null) {
      _ledger[bookId] = TombstoneLedgerEntry(
        bookId: old.bookId,
        deletedAt: old.deletedAt,
        pushed: true,
        contentHash: old.contentHash,
      );
    }
  }

  @override
  Future<int> purgeTombstones({required DateTime olderThan}) async {
    final doomed = _ledger.values
        .where((e) => e.deletedAt.isBefore(olderThan))
        .map((e) => e.bookId)
        .toList();
    for (final id in doomed) {
      _ledger.remove(id);
    }
    return doomed.length;
  }

  @override
  Future<BackendCursorSnapshot> cursorSnapshot(String backendKey) async =>
      _cursors[backendKey] ?? BackendCursorSnapshot(backendKey: backendKey);

  @override
  Future<void> saveCursorSnapshot(BackendCursorSnapshot snapshot) async {
    _cursors[snapshot.backendKey] = snapshot;
  }

  // ── SyncStore：分组同步状态 ──────────────────────────────────────────

  @override
  Future<int> nextGroupRev(String groupId, {int atLeast = 0}) async {
    final next = _max((_groupRevCounters[groupId] ?? 0) + 1, atLeast);
    _groupRevCounters[groupId] = next;
    return next;
  }

  @override
  Future<GroupSyncStateSnapshot?> groupSyncState(
    String groupId,
    String backendKey,
  ) async {
    return _groupStates['$backendKey|$groupId'];
  }

  @override
  Future<void> saveGroupSyncState(GroupSyncStateSnapshot state) async {
    _groupStates['${state.backendKey}|${state.groupId}'] = state;
  }

  @override
  Future<List<GroupSyncStateSnapshot>> allGroupSyncStates(
    String backendKey,
  ) async {
    return _groupStates.values
        .where((s) => s.backendKey == backendKey)
        .toList(growable: false);
  }

  static int _max(int a, int b) => a >= b ? a : b;
}

/// [LocalLibrary] 的文件系统参考实现。
///
/// 元数据行存内存（模拟 `books`/`progress` 表），正文文件写真实文件系统：
/// `root/files/books/{bookId}/{bookId}.{ext}`。供测试与参考实现复用。
class InMemoryLocalLibrary implements LocalLibrary {
  InMemoryLocalLibrary(this.root) {
    Directory('${root.path}/files/books').createSync(recursive: true);
  }

  final Directory root;

  /// 本地书行（模拟 books 表 + progress 表的内存投影）。
  final Map<String, _LocalRow> _rows = {};

  /// 本地分组行（模拟 book_groups 表的内存投影，docs/05 §2.1）。
  final Map<String, _LocalGroupRow> _groups = {};

  int _cloudMissingMarks = 0;
  int _adoptCalls = 0;
  int _applyRemoteCalls = 0;

  /// 诊断计数：applyRemoteMeta 调用次数（304 跳过测试断言用）。
  int get applyRemoteCalls => _applyRemoteCalls;

  /// 诊断计数：markCloudMissing 调用次数。
  int get cloudMissingMarks => _cloudMissingMarks;

  /// 诊断计数：adoptCloudBook 调用次数。
  int get adoptCalls => _adoptCalls;

  String _bookDir(String bookId) => '${root.path}/files/books/$bookId';

  String _contentFileName(String bookId, String format) => '$bookId.$format';

  @override
  Future<List<LocalBookSnapshot>> listBooks() async => _rows.values
      .map(
        (r) => LocalBookSnapshot(
          bookId: r.bookId,
          meta: _rowToSkeletonMeta(r),
          exists: true,
          dirty: r.dirty,
          hasBaseRev: r.hasBaseRev,
          baseRev: r.baseRev,
          hasLocalContent: r.localPath != null,
        ),
      )
      .toList(growable: false);

  @override
  Future<LocalBookSnapshot?> book(String bookId) async {
    final r = _rows[bookId];
    if (r == null) return null;
    return LocalBookSnapshot(
      bookId: r.bookId,
      meta: _rowToSkeletonMeta(r),
      exists: true,
      dirty: r.dirty,
      hasBaseRev: r.hasBaseRev,
      baseRev: r.baseRev,
      hasLocalContent: r.localPath != null,
    );
  }

  @override
  Future<void> applyRemoteMeta(BookMeta meta) async {
    _applyRemoteCalls++;
    if (meta.isTombstone) {
      // 从书库视图移除；正文文件保留为游离文件（docs/04 §7.1.2）。
      _rows.remove(meta.bookId);
      return;
    }
    final existing = _rows[meta.bookId];
    final localPath = _existingContentPath(meta.bookId, meta.book.format);
    // 分组归属（FR-107，docs/05 §2.2）：远端分组本地不存在 → 视为未分组
    // （不得写入悬空外键；分组稍后到达时会由其 meta 应用补回）。
    final groupId = meta.groupId != null && _groups.containsKey(meta.groupId)
        ? meta.groupId
        : null;
    _rows[meta.bookId] = _LocalRow(
      bookId: meta.bookId,
      title: meta.book.title,
      author: meta.book.author,
      format: meta.book.format,
      fileName: meta.book.fileName,
      contentHash: meta.book.contentHash,
      sizeBytes: meta.book.sizeBytes,
      tocFingerprint: meta.book.tocFingerprint,
      addedAt: meta.createdAt,
      localPath: localPath,
      progress: meta.progress,
      totalSeconds: meta.reading.totalSeconds,
      lastReadAt: meta.reading.lastReadAt,
      // 应用远端 → 本地与云端一致，清除待推送标记。
      dirty: false,
      hasBaseRev: existing?.hasBaseRev ?? false,
      baseRev: existing?.baseRev ?? 0,
      groupId: groupId,
    );
  }

  @override
  Future<void> markCloudMissing(String bookId) async {
    _cloudMissingMarks++;
    final r = _rows[bookId];
    if (r != null) _rows[bookId] = r.withCloudMissing(true);
  }

  @override
  Future<void> adoptCloudBook({
    required String localBookId,
    required String cloudBookId,
    required BookMeta cloudMeta,
  }) async {
    _adoptCalls++;
    final local = _rows.remove(localBookId);
    // 正文文件挪到云端 bookId 名下（本地有才挪）。
    String? newPath;
    if (local?.localPath != null) {
      final source = File(local!.localPath!);
      if (await source.exists()) {
        final dir = Directory(_bookDir(cloudBookId));
        await dir.create(recursive: true);
        newPath = '${dir.path}/${_contentFileName(cloudBookId, local.format)}';
        final target = File(newPath);
        if (await target.exists()) await target.delete();
        await source.rename(newPath);
      }
    }
    // 进度按 updatedAt 与云端 LWW 合并（docs/05 §4.3）。
    final remoteProgress = cloudMeta.progress;
    final localProgress = local?.progress;
    ReadingProgress? progress;
    if (remoteProgress == null) {
      progress = localProgress;
    } else if (localProgress == null) {
      progress = remoteProgress;
    } else {
      progress = localProgress.updatedAt.isAfter(remoteProgress.updatedAt)
          ? localProgress
          : remoteProgress;
    }
    _rows[cloudBookId] = _LocalRow(
      bookId: cloudBookId,
      title: cloudMeta.book.title,
      author: cloudMeta.book.author,
      format: cloudMeta.book.format,
      fileName: cloudMeta.book.fileName,
      contentHash: cloudMeta.book.contentHash,
      sizeBytes: cloudMeta.book.sizeBytes,
      tocFingerprint: cloudMeta.book.tocFingerprint,
      addedAt: local?.addedAt ?? cloudMeta.createdAt,
      localPath: newPath,
      progress: progress,
      totalSeconds: (local?.totalSeconds ?? 0) + cloudMeta.reading.totalSeconds,
      lastReadAt: _maxTime(local?.lastReadAt, cloudMeta.reading.lastReadAt),
      dirty: false,
      hasBaseRev: true,
      baseRev: cloudMeta.rev,
      groupId:
          cloudMeta.groupId != null && _groups.containsKey(cloudMeta.groupId)
          ? cloudMeta.groupId
          : local?.groupId,
    );
  }

  @override
  Future<BookMeta> buildLocalMeta(
    String bookId, {
    required int rev,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  }) async {
    final r = _rows[bookId];
    if (r == null) {
      throw StateError('本地不存在该书，无法构建 meta：$bookId');
    }
    return _rowToSkeletonMeta(
      r,
      rev: rev,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  @override
  Future<String?> localContentPath(String bookId) async =>
      _rows[bookId]?.localPath;

  @override
  Future<String> contentTargetPath(
    String bookId, {
    required String format,
  }) async => '${_bookDir(bookId)}/${_contentFileName(bookId, format)}';

  @override
  Future<String> contentPartPath(
    String bookId, {
    required String format,
  }) async => '${_bookDir(bookId)}/${_contentFileName(bookId, format)}.part';

  @override
  Future<void> commitContentFile(String bookId, String contentFile) async {
    final r = _rows[bookId];
    if (r == null) throw StateError('本地不存在该书：$bookId');
    final file = File(contentFile);
    if (!await file.exists()) {
      throw StateError('下载产物不存在：$contentFile');
    }
    _rows[bookId] = r.withLocalPath(contentFile);
  }

  @override
  Future<void> updateBookFileInfo(
    String bookId, {
    String? fileName,
    String? contentHash,
    int? sizeBytes,
    String? format,
  }) async {
    final r = _rows[bookId];
    if (r == null) {
      throw StateError('本地不存在该书，无法更新文件信息：$bookId');
    }
    // 仅更新非 null 实参对应的列（FR-410：app 已把新文件落盘并重解析）。
    var updated = r.withFileInfo(
      fileName: fileName,
      contentHash: contentHash,
      sizeBytes: sizeBytes,
      format: format,
    );
    // format 变化 → 按新扩展名重探本地正文路径（约定路径随之改变；
    // app 未落盘时为 null，引擎 replaceBookContent 会按 Corruption 报告）。
    if (format != null && format != r.format) {
      updated = updated.withLocalPathOrNull(
        _existingContentPath(bookId, format),
      );
    }
    _rows[bookId] = updated;
  }

  /// 测试辅助：导入一本本地书（复制文件入书库 + 建行，rev=1 dirty，docs/04 §5.3）。
  Future<void> importLocalBook({
    required String bookId,
    required String title,
    required String format,
    required String contentHash,
    required int sizeBytes,
    required File sourceFile,
    String author = '',
    DateTime? addedAt,
    bool dirty = true,
    String? groupId,
  }) async {
    final dir = Directory(_bookDir(bookId));
    await dir.create(recursive: true);
    final target = File('${dir.path}/${_contentFileName(bookId, format)}');
    await sourceFile.copy(target.path);
    _rows[bookId] = _LocalRow(
      bookId: bookId,
      title: title,
      author: author,
      format: format,
      fileName: '$title.$format',
      contentHash: contentHash,
      sizeBytes: sizeBytes,
      tocFingerprint: 'tfp:$bookId',
      addedAt: addedAt ?? DateTime.utc(2026, 1, 1),
      localPath: target.path,
      progress: null,
      totalSeconds: 0,
      lastReadAt: null,
      dirty: dirty,
      hasBaseRev: false,
      baseRev: 0,
      groupId: groupId,
    );
  }

  /// 测试辅助：直接写入阅读进度（dirty 置位，模拟本地阅读产生修改）。
  Future<void> updateProgress(
    String bookId, {
    required ReadingProgress progress,
    required int totalSeconds,
    required DateTime lastReadAt,
  }) async {
    final r = _rows[bookId]!;
    _rows[bookId] = r.withProgress(
      progress: progress,
      totalSeconds: totalSeconds,
      lastReadAt: lastReadAt,
      dirty: true,
    );
  }

  /// 测试辅助：直接标记已完成同步（写 sync_state 时同步本地行视图）。
  Future<void> markSynced(String bookId, {required int baseRev}) async {
    final r = _rows[bookId];
    if (r != null) {
      _rows[bookId] = r.withSynced(baseRev);
    }
  }

  /// 测试辅助：移除本地行（模拟 app softDelete 的书库视图移除；
  /// 正文文件保留，与 docs/04 §7.1 游离语义一致）。
  Future<void> removeLocalBook(String bookId) async {
    _rows.remove(bookId);
  }

  // ── LocalLibrary：分组（docs/05 §2.1）───────────────────────────────

  @override
  Future<List<LocalGroupSnapshot>> listGroups() async => _groups.values
      .map(
        (g) => LocalGroupSnapshot(
          groupId: g.groupId,
          name: g.name,
          sortOrder: g.sortOrder,
          createdAt: g.createdAt,
          exists: true,
          deleted: g.deleted,
          dirty: g.dirty,
          hasBaseRev: g.hasBaseRev,
          baseRev: g.baseRev,
        ),
      )
      .toList(growable: false);

  @override
  Future<LocalGroupSnapshot?> group(String groupId) async {
    final g = _groups[groupId];
    if (g == null) return null;
    return LocalGroupSnapshot(
      groupId: g.groupId,
      name: g.name,
      sortOrder: g.sortOrder,
      createdAt: g.createdAt,
      exists: true,
      deleted: g.deleted,
      dirty: g.dirty,
      hasBaseRev: g.hasBaseRev,
      baseRev: g.baseRev,
    );
  }

  @override
  Future<void> applyRemoteGroup(GroupMeta meta) async {
    if (meta.isTombstone) {
      // 分组消失 → 组内书籍回到未分组（外键 SET NULL 语义）。
      _groups.remove(meta.groupId);
      for (final row in _rows.values.toList()) {
        if (row.groupId == meta.groupId) {
          _rows[row.bookId] = row.withGroupId(null);
        }
      }
      return;
    }
    final existing = _groups[meta.groupId];
    _groups[meta.groupId] = _LocalGroupRow(
      groupId: meta.groupId,
      name: meta.name,
      sortOrder: meta.sortOrder,
      createdAt: existing?.createdAt ?? meta.createdAt,
      deleted: false,
      dirty: false,
      hasBaseRev: true,
      baseRev: meta.rev,
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
    final g = _groups[groupId];
    if (g == null) {
      throw StateError('本地不存在该分组，无法构建 meta：$groupId');
    }
    return GroupMeta(
      schemaVersion: kGroupSchemaVersion,
      groupId: g.groupId,
      rev: rev,
      deviceId: deviceId,
      deviceName: deviceName,
      createdAt: g.createdAt,
      updatedAt: now,
      name: g.name,
      sortOrder: g.sortOrder,
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
    final from = _groups.remove(fromGroupId);
    final to = _groups[toGroupId];
    _groups[toGroupId] = _LocalGroupRow(
      groupId: toGroupId,
      name: to == null || to.name.isEmpty ? toName : to.name,
      sortOrder: to?.sortOrder ?? toSortOrder,
      createdAt: to?.createdAt ?? from?.createdAt ?? DateTime.utc(2026, 1, 1),
      deleted: false,
      dirty: to?.dirty ?? false,
      hasBaseRev: to?.hasBaseRev ?? false,
      baseRev: to?.baseRev ?? 0,
    );
    for (final row in _rows.values.toList()) {
      if (row.groupId == fromGroupId) {
        // 归属变了 → 该书的 meta 变脏（需重新推送 groupId）。
        _rows[row.bookId] = row.withGroupId(toGroupId, markDirty: true);
      }
    }
  }

  /// 测试辅助：新建本地分组。
  Future<void> importLocalGroup({
    required String groupId,
    required String name,
    int sortOrder = 0,
    DateTime? createdAt,
    bool dirty = true,
  }) async {
    _groups[groupId] = _LocalGroupRow(
      groupId: groupId,
      name: name,
      sortOrder: sortOrder,
      createdAt: createdAt ?? DateTime.utc(2026, 1, 1),
      deleted: false,
      dirty: dirty,
      hasBaseRev: false,
      baseRev: 0,
    );
  }

  /// 测试辅助：重命名本地分组（标脏，待推送）。
  Future<void> renameLocalGroup(String groupId, String name) async {
    final g = _groups[groupId];
    if (g == null) throw StateError('本地不存在该分组：$groupId');
    _groups[groupId] = g.copyWith(name: name, dirty: true);
  }

  /// 测试辅助：本地删除分组（软删：行保留待推墓碑；组内书回到未分组）。
  Future<void> deleteLocalGroup(String groupId) async {
    final g = _groups[groupId];
    if (g == null) return;
    _groups[groupId] = g.copyWith(deleted: true, dirty: true);
    for (final row in _rows.values.toList()) {
      if (row.groupId == groupId) {
        _rows[row.bookId] = row.withGroupId(null);
      }
    }
  }

  /// 测试辅助：把书放进分组（改 group_id → 该书 meta 变脏）。
  Future<void> setBookGroup(String bookId, String? groupId) async {
    final r = _rows[bookId];
    if (r == null) throw StateError('本地不存在该书：$bookId');
    _rows[bookId] = r.withGroupId(groupId, markDirty: true);
  }

  String? _existingContentPath(String bookId, String format) {
    final candidate = File(
      '${_bookDir(bookId)}/${_contentFileName(bookId, format)}',
    );
    return candidate.existsSync() ? candidate.path : null;
  }

  BookMeta _rowToSkeletonMeta(
    _LocalRow r, {
    int? rev,
    String? deviceId,
    String? deviceName,
  }) {
    final resolvedRev = rev ?? (r.hasBaseRev ? r.baseRev : 1);
    final updatedAt = r.progress?.updatedAt ?? r.addedAt;
    return BookMeta(
      schemaVersion: kCurrentSchemaVersion,
      bookId: r.bookId,
      rev: resolvedRev,
      deviceId: deviceId ?? 'local',
      deviceName: deviceName ?? 'local',
      createdAt: r.addedAt,
      updatedAt: updatedAt,
      book: BookInfo(
        title: r.title,
        author: r.author,
        format: r.format,
        fileName: r.fileName,
        contentHash: r.contentHash,
        sizeBytes: r.sizeBytes,
        tocFingerprint: r.tocFingerprint,
      ),
      progress: r.progress,
      reading: ReadingStats(
        totalSeconds: r.totalSeconds,
        lastReadAt: r.lastReadAt ?? updatedAt,
      ),
      groupId: r.groupId,
    );
  }

  static DateTime _maxTime(DateTime? a, DateTime b) {
    if (a == null) return b;
    return a.isAfter(b) ? a : b;
  }
}

/// 本地书行（books + progress 表的联合内存投影）。
class _LocalRow {
  const _LocalRow({
    required this.bookId,
    required this.title,
    required this.author,
    required this.format,
    required this.fileName,
    required this.contentHash,
    required this.sizeBytes,
    required this.tocFingerprint,
    required this.addedAt,
    required this.localPath,
    required this.progress,
    required this.totalSeconds,
    required this.lastReadAt,
    required this.dirty,
    required this.hasBaseRev,
    required this.baseRev,
    this.groupId,
    this.cloudMissing = false,
  });

  final String bookId;
  final String title;
  final String author;
  final String format;
  final String fileName;
  final String contentHash;
  final int sizeBytes;
  final String tocFingerprint;
  final DateTime addedAt;

  /// 本地正文路径；null = 占位。
  final String? localPath;
  final ReadingProgress? progress;
  final int totalSeconds;
  final DateTime? lastReadAt;
  final bool dirty;
  final bool hasBaseRev;
  final int baseRev;

  /// 所属分组 id（FR-107，docs/05 §2.2）；null = 未分组。
  final String? groupId;
  final bool cloudMissing;

  _LocalRow withLocalPath(String path) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: path,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: cloudMissing,
  );

  /// FR-410 文件替换：仅更新非 null 实参对应的文件指征列。
  _LocalRow withFileInfo({
    String? fileName,
    String? contentHash,
    int? sizeBytes,
    String? format,
  }) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format ?? this.format,
    fileName: fileName ?? this.fileName,
    contentHash: contentHash ?? this.contentHash,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: localPath,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: cloudMissing,
  );

  /// 以可空路径覆盖 localPath（format 变化后重探；null = 占位）。
  _LocalRow withLocalPathOrNull(String? path) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: path,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: cloudMissing,
  );

  _LocalRow withProgress({
    required ReadingProgress progress,
    required int totalSeconds,
    required DateTime lastReadAt,
    required bool dirty,
  }) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: localPath,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: cloudMissing,
  );

  _LocalRow withSynced(int baseRev) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: localPath,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: false,
    hasBaseRev: true,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: cloudMissing,
  );

  _LocalRow withCloudMissing(bool flag) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: localPath,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: groupId,
    cloudMissing: flag,
  );

  /// 改所属分组（FR-107 拖拽归组；null = 移出分组）。
  ///
  /// [markDirty]：分组归属进入书籍 meta（docs/05 §2.2），改动即产生
  /// "未推送的本地修改"（app 侧按"本地 group_id ≠ 上次同步的 group_id"
  /// 动态判定 dirty，等价语义）。
  _LocalRow withGroupId(String? value, {bool markDirty = false}) => _LocalRow(
    bookId: bookId,
    title: title,
    author: author,
    format: format,
    fileName: fileName,
    contentHash: contentHash,
    sizeBytes: sizeBytes,
    tocFingerprint: tocFingerprint,
    addedAt: addedAt,
    localPath: localPath,
    progress: progress,
    totalSeconds: totalSeconds,
    lastReadAt: lastReadAt,
    dirty: markDirty ? true : dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
    groupId: value,
    cloudMissing: cloudMissing,
  );
}

/// 本地分组行（book_groups 表的内存投影，docs/05 §2.1）。
class _LocalGroupRow {
  const _LocalGroupRow({
    required this.groupId,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
    required this.deleted,
    required this.dirty,
    required this.hasBaseRev,
    required this.baseRev,
  });

  final String groupId;
  final String name;
  final int sortOrder;
  final DateTime createdAt;

  /// 本地已删除（待推墓碑）。
  final bool deleted;

  /// 名称/排序有未推送修改。
  final bool dirty;
  final bool hasBaseRev;
  final int baseRev;

  _LocalGroupRow copyWith({
    String? name,
    int? sortOrder,
    bool? deleted,
    bool? dirty,
  }) => _LocalGroupRow(
    groupId: groupId,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt,
    deleted: deleted ?? this.deleted,
    dirty: dirty ?? this.dirty,
    hasBaseRev: hasBaseRev,
    baseRev: baseRev,
  );
}
