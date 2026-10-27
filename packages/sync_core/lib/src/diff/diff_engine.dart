import '../backend/backend_adapter.dart';
import '../model/book_meta.dart';
import '../store/sync_store.dart';

/// 本地书籍快照：Diff 的输入投影（docs/04 §5.1 的"本地状态 L"）。
///
/// `meta` 为本地行投影出的**待推送形态**（字段尚未定 rev/设备信息的骨架，
/// 推送时由 [LocalLibrary.buildLocalMeta] 重建）；`exists=false` 时为 null。
class LocalBookSnapshot {
  const LocalBookSnapshot({
    required this.bookId,
    this.meta,
    required this.exists,
    required this.dirty,
    required this.hasBaseRev,
    required this.baseRev,
    required this.hasLocalContent,
  });

  final String bookId;

  /// 本地书库视图中的待推送 meta 投影；`exists=false` 时为 null。
  final BookMeta? meta;

  /// 是否存在于本地书库视图（占位书也算存在）。
  final bool exists;

  /// 是否有未推送的本地修改（进度/信息）。
  final bool dirty;

  /// 是否有过成功同步（sync_state 有 baseRev）。
  final bool hasBaseRev;
  final int baseRev;

  /// 正文文件是否在本地盘上（占位书为 false；游离文件为 true）。
  final bool hasLocalContent;
}

/// 正文传输需求：bookId + 期望的 contentHash / size（校验依据，docs/04 §5）。
class ContentNeed {
  const ContentNeed({required this.bookId, this.contentHash, this.sizeBytes});

  final String bookId;
  final String? contentHash; // `sha256:<hex>`
  final int? sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is ContentNeed &&
      other.bookId == bookId &&
      other.contentHash == contentHash &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(bookId, contentHash, sizeBytes);

  @override
  String toString() => 'ContentNeed($bookId)';
}

/// Diff 决策（docs/04 §5.1 七行矩阵的分类展开）。
enum SyncDecision {
  /// 第 1 行：双侧一致，无需动作。
  inSync,

  /// 第 2 行：本地落后（含远端为更高 rev 的 tombstone）→ 拉取 meta 应用。
  pullRemote,

  /// 第 3 行：本地领先 → 推送 meta（rev+1）。
  pushLocal,

  /// 第 4 行：双端并发修改 → §6 合并后推送。
  conflictMerge,

  /// 第 5 行：云端新增书 → 拉取 meta，书库显示占位，正文按需下载。
  newFromCloud,

  /// 第 6 行：云端已删且本地无该书 → 无操作；本地残留正文则为 orphan 提示。
  cloudTombstoneNoLocal,

  /// 第 7a 行：本地新书从未推送 → 推 meta + 正文（推送前先做 §5.3 哈希去重）。
  localNewPush,

  /// 第 7b 行：曾有 baseRev 但远端 meta 消失 → 保留本地，标记云端缺失。
  cloudMissing,

  /// 删除同步（docs/04 §7.1，非 Diff 矩阵行）：本端删除 → tombstone 推送
  /// （[全量同步](SyncEngine.fullSync) 对账本未推送条目补推时也用此值）。
  deletePush,
}

/// 单本书的 Diff 结论。
class SyncPlanEntry {
  const SyncPlanEntry({
    required this.bookId,
    required this.decision,
    this.remote,
    this.local,
    this.remoteIsTombstone = false,
    this.orphanHint = false,
  });

  final String bookId;
  final SyncDecision decision;

  /// 清单中的远端摘要（远端存在时）。
  final RemoteMetaStub? remote;

  /// 本地快照（本地存在时）。
  final LocalBookSnapshot? local;

  /// 远端当前是 tombstone（pullRemote 需按删除应用，docs/04 §7.1）。
  final bool remoteIsTombstone;

  /// 云端已删但本地残留正文文件（游离文件提示，docs/04 §7.1）。
  final bool orphanHint;

  @override
  String toString() => 'SyncPlanEntry($bookId, $decision)';
}

/// 一次 Diff 的完整计划：逐书决策 + 正文传输需求集合。
class SyncPlan {
  SyncPlan({required List<SyncPlanEntry> entries})
    : entries = List.unmodifiable(entries);

  /// 全部条目（含无动作行，供报告/诊断）。
  final List<SyncPlanEntry> entries;

  /// bookId → 决策。
  Map<String, SyncDecision> get decisions => {
    for (final e in entries) e.bookId: e.decision,
  };

  /// 需要拉取远端 meta 的条目（阶段 3 PullMetas 输入）。
  List<SyncPlanEntry> get pullNeeded => entries
      .where(
        (e) =>
            e.decision == SyncDecision.pullRemote ||
            e.decision == SyncDecision.conflictMerge ||
            e.decision == SyncDecision.newFromCloud,
      )
      .toList();

  /// 需要推送 meta 的条目（阶段 4 PushMetas 输入）。
  List<SyncPlanEntry> get pushNeeded => entries
      .where(
        (e) =>
            e.decision == SyncDecision.pushLocal ||
            e.decision == SyncDecision.conflictMerge ||
            e.decision == SyncDecision.localNewPush,
      )
      .toList();

  /// 正文缺失、待按需下载的集合（占位书，docs/04 §5.4）。
  ///
  /// newFromCloud 必下（本地无该书）；pullRemote 仅在本地正文缺失时列入。
  /// 清单 stub 不含正文 hash/size，故 newFromCloud 的校验字段为 null，
  /// 由引擎在拉到 meta 后补齐。
  List<ContentNeed> get needsDownload => entries
      .where(
        (e) =>
            e.decision == SyncDecision.newFromCloud ||
            (e.decision == SyncDecision.pullRemote &&
                e.local != null &&
                !e.local!.hasLocalContent),
      )
      .map(
        (e) => ContentNeed(
          bookId: e.bookId,
          contentHash: e.local?.meta?.book.contentHash,
          sizeBytes: e.local?.meta?.book.sizeBytes,
        ),
      )
      .toList();

  /// 待上传正文的集合（本端新书上架，docs/04 §5.3）。
  List<ContentNeed> get needsUpload => entries
      .where(
        (e) =>
            e.decision == SyncDecision.localNewPush &&
            (e.local?.hasLocalContent ?? false),
      )
      .map(
        (e) => ContentNeed(
          bookId: e.bookId,
          contentHash: e.local?.meta?.book.contentHash,
          sizeBytes: e.local?.meta?.book.sizeBytes,
        ),
      )
      .toList();
}

/// 差异比对引擎（docs/04 §5.1 决策矩阵，纯函数）。
///
/// 七行矩阵逐行判定；行内细分（7a/7b、orphan）由 [SyncPlanEntry] 的标志位区分。
/// baseRev 取 `syncStates[bookId]`（每后端权威值），缺失时回退
/// [LocalBookSnapshot] 的内联字段。
class DiffEngine {
  const DiffEngine();

  /// 对本地快照 × 远端清单 × 同步状态做全量比对。
  SyncPlan diff({
    required List<LocalBookSnapshot> local,
    required MetaListing remote,
    required Map<String, BookSyncStateSnapshot> syncStates,
  }) {
    final entries = <SyncPlanEntry>[];
    final ids = <String>{for (final s in local) s.bookId, ...remote.stubs.keys};
    for (final id in ids) {
      final snap = _find(local, id);
      final stub = remote.stubs[id];
      final state = syncStates[id];
      entries.add(_decide(id, snap, stub, state));
    }
    return SyncPlan(entries: entries);
  }

  /// 第 1-4 行：本地有、远端有；第 5-6 行：本地无、远端有；第 7a/7b 行：本地有、远端无。
  SyncPlanEntry _decide(
    String bookId,
    LocalBookSnapshot? snap,
    RemoteMetaStub? stub,
    BookSyncStateSnapshot? state,
  ) {
    if (snap != null && stub != null) {
      return _decideBothPresent(bookId, snap, stub, state);
    }
    if (snap == null && stub != null) {
      // 第 5 行：云端新书（非 tombstone）。
      if (!stub.deleted) {
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.newFromCloud,
          remote: stub,
        );
      }
      // 第 6 行：云端已删且本地书库无该书 → 无操作（orphan 提示）。
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.cloudTombstoneNoLocal,
        remote: stub,
        remoteIsTombstone: true,
      );
    }
    if (snap != null && stub == null) {
      // 第 7a 行：从未推送过 → 视为本地新书正常上架。
      final hasBase = state != null || snap.hasBaseRev;
      if (!hasBase) {
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.localNewPush,
          local: snap,
        );
      }
      // 第 7b 行：曾有 baseRev 而远端 meta 消失（网盘侧手工删除等异常）
      // → 保留本地，标记"云端缺失"，不删不推。
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.cloudMissing,
        local: snap,
      );
    }
    // 双侧都无（防御性输入，不应出现）。
    return SyncPlanEntry(bookId: bookId, decision: SyncDecision.inSync);
  }

  SyncPlanEntry _decideBothPresent(
    String bookId,
    LocalBookSnapshot snap,
    RemoteMetaStub stub,
    BookSyncStateSnapshot? state,
  ) {
    final hasBase = state != null || snap.hasBaseRev;
    final baseRev = state?.baseRev ?? snap.baseRev;

    // 远端是 tombstone（docs/04 §7：删除语义与正常 meta 同一定序）。
    if (stub.deleted) {
      if (!snap.exists) {
        // 第 6 行变体：书库视图已移除、云端 tombstone → 无操作。
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.cloudTombstoneNoLocal,
          remote: stub,
          remoteIsTombstone: true,
          orphanHint: snap.hasLocalContent,
        );
      }
      if (hasBase && stub.rev > baseRev) {
        // 落后于 tombstone → 拉取并按删除应用（第 2 行的 tombstone 形态）。
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.pullRemote,
          remote: stub,
          local: snap,
          remoteIsTombstone: true,
        );
      }
      if (snap.dirty) {
        // rev 未越过 base 且本地有修改 → 走推送（合并发生在写冲突路径）。
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.pushLocal,
          remote: stub,
          local: snap,
        );
      }
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.inSync,
        remote: stub,
        local: snap,
      );
    }

    // 无 baseRev 而云端已有该书（重装等）：无法判定祖先，保守走合并。
    if (!hasBase) {
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }

    // rev 回退（网盘回档等异常，rev 只增不变式被破坏）→ 保守走合并。
    if (stub.rev < baseRev) {
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }

    if (stub.rev == baseRev) {
      // 第 1/3 行。
      if (snap.dirty) {
        return SyncPlanEntry(
          bookId: bookId,
          decision: SyncDecision.pushLocal,
          remote: stub,
          local: snap,
        );
      }
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.inSync,
        remote: stub,
        local: snap,
      );
    }

    // stub.rev > baseRev：第 2 行（落后）或第 4 行（冲突）。
    if (snap.dirty) {
      return SyncPlanEntry(
        bookId: bookId,
        decision: SyncDecision.conflictMerge,
        remote: stub,
        local: snap,
      );
    }
    return SyncPlanEntry(
      bookId: bookId,
      decision: SyncDecision.pullRemote,
      remote: stub,
      local: snap,
    );
  }

  LocalBookSnapshot? _find(List<LocalBookSnapshot> list, String bookId) {
    for (final s in list) {
      if (s.bookId == bookId) return s;
    }
    return null;
  }
}
