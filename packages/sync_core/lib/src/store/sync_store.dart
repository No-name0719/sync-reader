/// 每书每后端的同步状态快照——与 docs/05 §5 `sync_state` 表一一对应。
class BookSyncStateSnapshot {
  const BookSyncStateSnapshot({
    required this.bookId,
    required this.backendKey,
    required this.baseRev,
    this.remoteEtag,
    this.lastSyncedMetaJson,
    required this.lastSyncedAt,
  });

  final String bookId;
  final String backendKey;

  /// 本地已确认"云端为该版本"的 rev（冲突检测基准，docs/04 §2）。
  final int baseRev;

  /// 上次同步的 meta 文件 ETag（WebDAV 条件请求用；可空）。
  final String? remoteEtag;

  /// 上次同步副本原文 = 冲突合并的公共祖先（docs/04 §6.3）。
  final String? lastSyncedMetaJson;

  final DateTime lastSyncedAt;
}

/// tombstone 本地账本条目——与 docs/05 §5 `deleted_books` 表一一对应。
class TombstoneLedgerEntry {
  const TombstoneLedgerEntry({
    required this.bookId,
    required this.deletedAt,
    required this.pushed,
    required this.contentHash,
  });

  final String bookId;
  final DateTime deletedAt;

  /// tombstone 是否已上云。
  final bool pushed;

  /// 游离文件重关联比对用（`sha256:<hex>`）。
  final String contentHash;
}

/// 每后端的同步游标与配额累计——与 docs/05 §5 `sync_cursor` 表一一对应。
class BackendCursorSnapshot {
  const BackendCursorSnapshot({
    required this.backendKey,
    this.changesCursor,
    this.metaListingEtag,
    this.lastFullSyncAt,
    this.quotaUpBytes = 0,
    this.quotaDownBytes = 0,
    this.quotaMonth,
  });

  final String backendKey;

  /// REST 模式服务端游标；WebDAV 为 null。
  final String? changesCursor;

  /// WebDAV PROPFIND 响应 ETag（无则全量列）。
  final String? metaListingEtag;

  final DateTime? lastFullSyncAt;

  /// 本自然月上行/下行累计字节（docs/04 §8.3 配额闸门）。
  final int quotaUpBytes;
  final int quotaDownBytes;

  /// 配额所属自然月（如 '2026-10'）；跨月自动清零由实现保证。
  final String? quotaMonth;
}

/// 持久化同步状态的纯接口（docs/05 §5 `sync_state` / `deleted_books` /
/// `sync_cursor` 三表）。app 侧以 drift 实现；引擎只依赖本接口。
///
/// 实现不变式（docs/05 §6）：`rev` 持久计数器只增不减。
abstract interface class SyncStore {
  /// 读取设备 ID；不存在时以 [generate] 生成并持久化（首次启动 ULID）。
  Future<String> loadOrCreateDeviceId({required String Function() generate});

  /// 取该书写端计数器的下一个 rev（只增不减，docs/05 §6 不变式 1）。
  ///
  /// `atLeast`：结果不得小于该值——合并结果的 rev 可能超过本地计数器
  /// （`max(local, remote) + 1`），推送合并结果后据此把计数器抬到云端水位。
  Future<int> nextRev(String bookId, {int atLeast});

  /// 读单本同步状态；从未同步过返回 null。
  Future<BookSyncStateSnapshot?> syncState(String bookId, String backendKey);

  /// 写（覆盖）单本同步状态。
  Future<void> saveSyncState(BookSyncStateSnapshot state);

  /// 某后端全部书籍的同步状态。
  Future<List<BookSyncStateSnapshot>> allSyncStates(String backendKey);

  /// tombstone 本地账本全量（docs/05 §5 `deleted_books`）。
  Future<List<TombstoneLedgerEntry>> tombstoneLedger();

  /// 记录一条 tombstone（已存在则覆盖）。
  Future<void> recordTombstone(TombstoneLedgerEntry entry);

  /// 标记 tombstone 已上云。
  Future<void> markTombstonePushed(String bookId);

  /// 清理 [olderThan]（含）之前的账本条目，返回清理数量
  /// （30 天保留期，docs/04 §7.3：过期后不再参与合并决策）。
  Future<int> purgeTombstones({required DateTime olderThan});

  /// 读某后端的游标快照；无记录返回全空默认值。
  Future<BackendCursorSnapshot> cursorSnapshot(String backendKey);

  /// 写（覆盖）某后端的游标快照。
  Future<void> saveCursorSnapshot(BackendCursorSnapshot snapshot);
}
