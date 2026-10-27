/// DriftSyncStore 全接口行为测试（内存 drift 库）：
/// deviceId 安全存储读写、nextRev atLeast 抬升（per (bookId, backendKey)）、
/// 同步状态/账本/游标 CRUD、quota 跨月清零、purge 严格早于边界。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/core/ulid.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late DriftSyncStore store;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    store = DriftSyncStore(
      db: db,
      credentials: credentials,
      backendKey: 'webdav',
    );
  });

  tearDown(() async => db.close());

  BookSyncStateSnapshot state(
    String bookId, {
    int baseRev = 1,
    String backendKey = 'webdav',
    String? etag,
    DateTime? at,
  }) => BookSyncStateSnapshot(
    bookId: bookId,
    backendKey: backendKey,
    baseRev: baseRev,
    remoteEtag: etag,
    lastSyncedMetaJson: '{"bookId":"$bookId"}',
    lastSyncedAt: at ?? DateTime.fromMillisecondsSinceEpoch(1000),
  );

  group('deviceId（安全存储，docs/03 §4.4）', () {
    test('首次生成并持久化；再次读取同一 ID', () async {
      final id1 = await store.loadOrCreateDeviceId(generate: generateUlid);
      expect(isValidUlid(id1), isTrue);
      expect(credentials.values['device.id'], id1);
      final id2 = await store.loadOrCreateDeviceId(generate: () => 'OTHER');
      expect(id2, id1);
    });
  });

  group('nextRev（per (bookId, backendKey) 计数器，docs/05 §6 不变式 1）', () {
    test('无状态从 1 起；atLeast 抬升不回落', () async {
      expect(await store.nextRev('b1', atLeast: 0), 1);
      expect(await store.nextRev('b1', atLeast: 5), 5);
    });

    test('以 sync_state.baseRev 作持久基线：保存后抬升', () async {
      await store.saveSyncState(state('b1', baseRev: 3));
      expect(await store.nextRev('b1', atLeast: 0), 4);
      // 合并抬升：atLeast 超过基线 +1。
      expect(await store.nextRev('b1', atLeast: 10), 10);
      // 引擎持久化合并结果（saveSyncState）后基线抬到 10。
      await store.saveSyncState(state('b1', baseRev: 10));
      expect(await store.nextRev('b1', atLeast: 0), 11);
    });

    test('per (bookId, backendKey)：书间独立、后端间独立', () async {
      await store.saveSyncState(state('b1', baseRev: 3));
      await store.saveSyncState(state('b2', baseRev: 7));
      await store.saveSyncState(
        state('b1', baseRev: 9, backendKey: 'server:L1'),
      );
      expect(await store.nextRev('b1', atLeast: 0), 4);
      expect(await store.nextRev('b2', atLeast: 0), 8);
      // backendKey='webdav' 的计数器不受 server 后端行影响（FR-405 单后端）。
      final serverStore = DriftSyncStore(
        db: db,
        credentials: credentials,
        backendKey: 'server:L1',
      );
      expect(await serverStore.nextRev('b1', atLeast: 0), 10);
    });
  });

  group('同步状态', () {
    test('写读对称；未同步返回 null；allSyncStates 按后端过滤', () async {
      expect(await store.syncState('b1', 'webdav'), isNull);
      await store.saveSyncState(state('b1', baseRev: 2, etag: 'w/abc'));
      await store.saveSyncState(
        state('b2', baseRev: 1, backendKey: 'server:L1'),
      );
      final got = await store.syncState('b1', 'webdav');
      expect(got, isNotNull);
      expect(got!.baseRev, 2);
      expect(got.remoteEtag, 'w/abc');
      expect(got.lastSyncedMetaJson, '{"bookId":"b1"}');
      final webdavStates = await store.allSyncStates('webdav');
      expect(webdavStates, hasLength(1));
      expect(webdavStates.single.bookId, 'b1');
      expect(await store.allSyncStates('server:L1'), hasLength(1));
    });
  });

  group('tombstone 账本（docs/04 §7.3）', () {
    test('记录 / 标记已上云 / 全量读取', () async {
      await store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: 'b1',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          pushed: false,
          contentHash: 'sha256:x',
        ),
      );
      await store.markTombstonePushed('b1');
      final ledger = await store.tombstoneLedger();
      expect(ledger.single.pushed, isTrue);
      // 重复记录覆盖。
      await store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: 'b1',
          deletedAt: DateTime.fromMillisecondsSinceEpoch(2000),
          pushed: true,
          contentHash: 'sha256:x',
        ),
      );
      expect(
        (await store.tombstoneLedger()).single.deletedAt,
        DateTime.fromMillisecondsSinceEpoch(2000),
      );
    });

    test('purge 严格早于边界（isBefore）：边界当刻保留', () async {
      final cutoff = DateTime.fromMillisecondsSinceEpoch(10_000);
      await store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: 'old',
          deletedAt: cutoff.subtract(const Duration(days: 1)),
          pushed: true,
          contentHash: 'sha256:1',
        ),
      );
      await store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: 'edge',
          deletedAt: cutoff,
          pushed: true,
          contentHash: 'sha256:2',
        ),
      );
      await store.recordTombstone(
        TombstoneLedgerEntry(
          bookId: 'new',
          deletedAt: cutoff.add(const Duration(days: 1)),
          pushed: true,
          contentHash: 'sha256:3',
        ),
      );
      final purged = await store.purgeTombstones(olderThan: cutoff);
      expect(purged, 1);
      final ids = (await store.tombstoneLedger()).map((e) => e.bookId).toSet();
      expect(ids, {'edge', 'new'});
    });
  });

  group('游标快照与配额计数（docs/04 §8.3）', () {
    test('无记录返回全空默认值；写读对称', () async {
      final empty = await store.cursorSnapshot('webdav');
      expect(empty.changesCursor, isNull);
      expect(empty.quotaUpBytes, 0);
      await store.saveCursorSnapshot(
        BackendCursorSnapshot(
          backendKey: 'webdav',
          changesCursor: 'c-42',
          metaListingEtag: 'w/list',
          lastFullSyncAt: DateTime.fromMillisecondsSinceEpoch(5000),
          quotaUpBytes: 10,
          quotaDownBytes: 20,
          quotaMonth: '2026-10',
        ),
      );
      final got = await store.cursorSnapshot('webdav');
      expect(got.changesCursor, 'c-42');
      expect(got.quotaDownBytes, 20);
    });

    test('addQuotaUsage 同月累加', () async {
      final now = DateTime(2026, 10, 15);
      await store.addQuotaUsage(upBytes: 100, downBytes: 200, now: now);
      final snap = await store.addQuotaUsage(
        upBytes: 30,
        downBytes: 40,
        now: now,
      );
      expect(snap.quotaUpBytes, 130);
      expect(snap.quotaDownBytes, 240);
      expect(snap.quotaMonth, '2026-10');
    });

    test('addQuotaUsage 跨月自动清零再累加', () async {
      await store.addQuotaUsage(
        upBytes: 1000,
        downBytes: 2000,
        now: DateTime(2026, 9, 28),
      );
      final next = await store.addQuotaUsage(
        upBytes: 5,
        downBytes: 6,
        now: DateTime(2026, 10, 1),
      );
      expect(next.quotaUpBytes, 5);
      expect(next.quotaDownBytes, 6);
      expect(next.quotaMonth, '2026-10');
      // 保留游标字段（清零不清游标）。
      await store.saveCursorSnapshot(
        BackendCursorSnapshot(
          backendKey: 'webdav',
          changesCursor: 'keep-me',
          quotaUpBytes: 1,
          quotaDownBytes: 1,
          quotaMonth: '2026-09',
        ),
      );
      final rolled = await store.addQuotaUsage(
        upBytes: 0,
        downBytes: 0,
        now: DateTime(2026, 10, 2),
      );
      expect(rolled.changesCursor, 'keep-me');
    });
  });
}
