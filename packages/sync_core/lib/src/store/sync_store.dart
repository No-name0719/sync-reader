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

/// 分组同步状态快照——与 docs/05 §5 `group_sync_state` 表一一对应。
///
/// 与 [BookSyncStateSnapshot] 同构但独立成表：分组是**独立文件类型**
/// （`groups/{groupId}.json`），写端 rev 计数器与公共祖先缓存都按
/// groupId 维度维护（docs/05 §2.1）。
class GroupSyncStateSnapshot {
  const GroupSyncStateSnapshot({
    required this.groupId,
    required this.backendKey,
    required this.baseRev,
    this.remoteEtag,
    this.lastSyncedGroupJson,
    required this.lastSyncedAt,
  });

  final String groupId;
  final String backendKey;

  /// 本地已确认"云端为该版本"的 rev（乐观锁基线）。
  final int baseRev;

  /// 上次同步的分组文件 ETag（WebDAV 条件请求用；可空）。
  final String? remoteEtag;

  /// 上次同步副本原文 = 冲突合并的公共祖先（docs/04 §6.3）。
  final String? lastSyncedGroupJson;

  final DateTime lastSyncedAt;
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

  /// 清理**严格早于** [olderThan] 的账本条目（不含边界），返回清理数量。
  ///
  /// 边界语义与云端 GC 对齐：云端只删 `deletedAt` 严格大于 90 天的
  /// tombstone（`isBefore(cutoff)`），本地账本同步清理同一集合。
  /// 引擎在云端 90 天 GC 之后调用（docs/04 §7.3"本地 deleted_books 同步
  /// 清理"）；30 天期限只约束上层对账本时间戳的消费（重关联窗口），
  /// 账本本身保留到 90 天。
  Future<int> purgeTombstones({required DateTime olderThan});

  /// 读某后端的游标快照；无记录返回全空默认值。
  Future<BackendCursorSnapshot> cursorSnapshot(String backendKey);

  /// 写（覆盖）某后端的游标快照。
  Future<void> saveCursorSnapshot(BackendCursorSnapshot snapshot);

  // ── 分组同步状态（docs/05 §5 `group_sync_state`）─────────────────────

  /// 取该分组写端计数器的下一个 rev（只增不减，docs/05 §6 不变式 1）。
  Future<int> nextGroupRev(String groupId, {int atLeast});

  /// 读单个分组的同步状态；从未同步过返回 null。
  Future<GroupSyncStateSnapshot?> groupSyncState(
    String groupId,
    String backendKey,
  );

  /// 写（覆盖）单个分组的同步状态。
  Future<void> saveGroupSyncState(GroupSyncStateSnapshot state);

  /// 某后端全部分组的同步状态。
  Future<List<GroupSyncStateSnapshot>> allGroupSyncStates(String backendKey);
}
