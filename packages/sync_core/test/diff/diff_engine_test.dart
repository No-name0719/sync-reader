import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// docs/04 §5.1 七行决策矩阵逐行用例（含 7a/7b 与 orphan 细分）。
void main() {
  final differ = const DiffEngine();

  SyncPlan diffOf({
    List<LocalBookSnapshot> local = const [],
    required Map<String, RemoteMetaStub> remote,
    Map<String, BookSyncStateSnapshot> states = const {},
  }) => differ.diff(
    local: local,
    remote: MetaListing(stubs: remote),
    syncStates: states,
  );

  BookSyncStateSnapshot stateAt(
    String bookId,
    int baseRev, {
    String? metaJson,
  }) => BookSyncStateSnapshot(
    bookId: bookId,
    backendKey: 'webdav',
    baseRev: baseRev,
    remoteEtag: 'etag-$baseRev',
    lastSyncedMetaJson: metaJson,
    lastSyncedAt: t0,
  );

  group('docs/04 §5.1 决策矩阵', () {
    test('第 1 行：本地无 dirty 且远端 rev == baseRev → inSync（无动作）', () {
      final id = bookIdOf(1);
      final plan = diffOf(
        local: [buildSnapshot(bookId: id, dirty: false, baseRev: 2)],
        remote: {id: buildStub(bookId: id, rev: 2)},
        states: {id: stateAt(id, 2)},
      );
      expect(plan.decisions[id], SyncDecision.inSync);
      expect(plan.pullNeeded, isEmpty);
      expect(plan.pushNeeded, isEmpty);
      expect(plan.needsDownload, isEmpty);
      expect(plan.needsUpload, isEmpty);
    });

    test('第 2 行：本地干净且远端 rev > baseRev → pullRemote；正文缺失列入 needsDownload', () {
      final id = bookIdOf(2);
      final meta = buildMeta(
        bookId: id,
        rev: 5,
        content: [1, 2, 3],
        sizeBytes: 3,
      );
      final plan = diffOf(
        local: [
          buildSnapshot(
            bookId: id,
            meta: meta,
            dirty: false,
            baseRev: 2,
            hasLocalContent: false,
          ),
        ],
        remote: {id: buildStub(bookId: id, rev: 5)},
        states: {id: stateAt(id, 2)},
      );
      expect(plan.decisions[id], SyncDecision.pullRemote);
      expect(plan.needsDownload.map((n) => n.bookId), [id]);
      expect(plan.needsDownload.single.contentHash, meta.book.contentHash);
    });

    test(
      '第 2 行变体：远端为更高 rev 的 tombstone → pullRemote 且 remoteIsTombstone=true',
      () {
        final id = bookIdOf(3);
        final plan = diffOf(
          local: [buildSnapshot(bookId: id, dirty: false, baseRev: 1)],
          remote: {id: buildStub(bookId: id, rev: 2, deleted: true)},
          states: {id: stateAt(id, 1)},
        );
        final entry = plan.entries.single;
        expect(entry.decision, SyncDecision.pullRemote);
        expect(entry.remoteIsTombstone, isTrue);
        expect(plan.needsDownload, isEmpty, reason: 'tombstone 不需要下载正文');
      },
    );

    test('第 3 行：本地 dirty 且远端 rev == baseRev → pushLocal（rev+1 推送）', () {
      final id = bookIdOf(4);
      final plan = diffOf(
        local: [buildSnapshot(bookId: id, dirty: true, baseRev: 3)],
        remote: {id: buildStub(bookId: id, rev: 3)},
        states: {id: stateAt(id, 3)},
      );
      expect(plan.decisions[id], SyncDecision.pushLocal);
      expect(plan.pushNeeded.map((e) => e.bookId), [id]);
      expect(plan.needsUpload, isEmpty, reason: '正文未变不重传');
    });

    test('第 4 行：本地 dirty 且远端 rev > baseRev → conflictMerge（§6 合并后推送）', () {
      final id = bookIdOf(5);
      final plan = diffOf(
        local: [buildSnapshot(bookId: id, dirty: true, baseRev: 2)],
        remote: {id: buildStub(bookId: id, rev: 6)},
        states: {id: stateAt(id, 2)},
      );
      expect(plan.decisions[id], SyncDecision.conflictMerge);
      expect(plan.pullNeeded.map((e) => e.bookId), [
        id,
      ], reason: '冲突需先拉远端 meta');
      expect(plan.pushNeeded.map((e) => e.bookId), [id]);
    });

    test('第 5 行：本地无、远端非 tombstone → newFromCloud（占位 + needsDownload）', () {
      final id = bookIdOf(6);
      final plan = diffOf(
        local: const [],
        remote: {id: buildStub(bookId: id, rev: 1)},
      );
      expect(plan.decisions[id], SyncDecision.newFromCloud);
      expect(plan.pullNeeded.map((e) => e.bookId), [id]);
      expect(plan.needsDownload.map((n) => n.bookId), [id]);
    });

    test('第 6 行：本地无、远端 tombstone → cloudTombstoneNoLocal（无操作）', () {
      final id = bookIdOf(7);
      final plan = diffOf(
        local: const [],
        remote: {id: buildStub(bookId: id, rev: 2, deleted: true)},
      );
      final entry = plan.entries.single;
      expect(entry.decision, SyncDecision.cloudTombstoneNoLocal);
      expect(plan.pullNeeded, isEmpty);
      expect(plan.pushNeeded, isEmpty);
    });

    test('第 6 行细分：书库已移除但正文残留 → cloudTombstoneNoLocal 且 orphanHint=true', () {
      final id = bookIdOf(8);
      final plan = diffOf(
        local: [
          // exists=false：已从书库视图移除；正文文件仍在盘（游离文件）。
          buildSnapshot(
            bookId: id,
            exists: false,
            baseRev: 2,
            hasLocalContent: true,
          ),
        ],
        remote: {id: buildStub(bookId: id, rev: 2, deleted: true)},
        states: {id: stateAt(id, 2)},
      );
      final entry = plan.entries.single;
      expect(entry.decision, SyncDecision.cloudTombstoneNoLocal);
      expect(entry.orphanHint, isTrue);
    });

    test('第 7a 行：本地新书从未推送且远端无 → localNewPush（推 meta+正文，needsUpload）', () {
      final id = bookIdOf(9);
      final meta = buildMeta(bookId: id, rev: 1, content: [4, 5], sizeBytes: 2);
      final plan = diffOf(
        local: [
          buildSnapshot(bookId: id, meta: meta, dirty: true, hasBaseRev: false),
        ],
        remote: const {},
      );
      expect(plan.decisions[id], SyncDecision.localNewPush);
      expect(plan.pushNeeded.map((e) => e.bookId), [id]);
      expect(plan.needsUpload.single.contentHash, meta.book.contentHash);
    });

    test('第 7b 行：曾有 baseRev 但远端 meta 消失 → cloudMissing（保留本地，不删不推）', () {
      final id = bookIdOf(10);
      final plan = diffOf(
        local: [buildSnapshot(bookId: id, dirty: false, baseRev: 4)],
        remote: const {},
        states: {id: stateAt(id, 4)},
      );
      expect(plan.decisions[id], SyncDecision.cloudMissing);
      expect(plan.pushNeeded, isEmpty, reason: '不推');
      expect(plan.needsUpload, isEmpty);
      expect(plan.needsDownload, isEmpty);
    });

    test('混合书库：七行在同一清单中互不干扰', () {
      final a = bookIdOf(1), b = bookIdOf(2), c = bookIdOf(3), d = bookIdOf(4);
      final plan = diffOf(
        local: [
          buildSnapshot(bookId: a, dirty: false, baseRev: 1),
          buildSnapshot(bookId: b, dirty: true, baseRev: 1),
          buildSnapshot(bookId: c, dirty: true, hasBaseRev: false),
        ],
        remote: {
          a: buildStub(bookId: a, rev: 1),
          b: buildStub(bookId: b, rev: 1),
          d: buildStub(bookId: d, rev: 1),
        },
        states: {a: stateAt(a, 1), b: stateAt(b, 1)},
      );
      expect(plan.decisions[a], SyncDecision.inSync);
      expect(plan.decisions[b], SyncDecision.pushLocal);
      expect(plan.decisions[c], SyncDecision.localNewPush);
      expect(plan.decisions[d], SyncDecision.newFromCloud);
    });
  });
}
