/// 分组云端同步的 app 层数据测试（FR-107，docs/05 §2.1）：
/// - `books.group_id` ↔ 书籍 meta 的往返（buildLocalMeta / applyRemoteMeta）；
/// - 远端 groupId 本地不存在时**不写悬空外键**；
/// - 远端分组 meta 的应用（新建 / 改名 / 墓碑 → 组内书回未分组）；
/// - 同名分组合并（名称级去重）：书籍外键迁移 + 源分组行删除；
/// - dirty 判定：分组改名 / 书籍换组 → 产生"未推送的本地修改"。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';

void main() {
  late AppDatabase db;
  late DriftLocalLibrary library;
  late Directory tmpDir;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    tmpDir = await Directory.systemTemp.createTemp('syncr_group');
    final fileStore = BookFileStore(tmpDir);
    await fileStore.ensureLayout();
    library = DriftLocalLibrary(db: db, fileStore: Future.value(fileStore));
  });

  tearDown(() async {
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  /// 造一本书（仅必填列）。
  Future<void> seedBook(String id, {String? groupId}) async {
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: id,
        title: '书$id',
        format: 'txt',
        fileName: '$id.txt',
        contentHash: 'sha256:$id',
        sizeBytes: 10,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1,
        localPath: Value('/tmp/$id'),
        groupId: Value(groupId),
      ),
    );
  }

  /// 构造书籍 meta（books 表 → 云端形态）。
  BookMeta bookMeta(
    String bookId, {
    String? groupId,
    int rev = 1,
    String deviceId = '01DEVA000000000000',
  }) => BookMeta(
    schemaVersion: kCurrentSchemaVersion,
    bookId: bookId,
    rev: rev,
    deviceId: deviceId,
    deviceName: '设备A',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    book: BookInfo(
      title: '云端书',
      author: '',
      format: 'txt',
      fileName: '$bookId.txt',
      contentHash: 'sha256:$bookId',
      sizeBytes: 10,
      tocFingerprint: 'tfp:0000000000000000',
    ),
    reading: ReadingStats(
      totalSeconds: 0,
      lastReadAt: DateTime.fromMillisecondsSinceEpoch(2000),
    ),
    groupId: groupId,
  );

  /// 构造分组 meta（云端 `groups/{groupId}.json`）。
  GroupMeta groupMeta(
    String groupId, {
    String name = '小说',
    int sortOrder = 0,
    int rev = 1,
    bool deleted = false,
  }) => GroupMeta(
    schemaVersion: kGroupSchemaVersion,
    groupId: groupId,
    rev: rev,
    deviceId: '01DEVA000000000000',
    deviceName: '设备A',
    createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
    name: name,
    sortOrder: sortOrder,
    deleted: deleted,
    deletedAt: deleted ? DateTime.fromMillisecondsSinceEpoch(3000) : null,
  );

  group('books.group_id ↔ 书籍 meta 往返（docs/05 §2.2）', () {
    test('buildLocalMeta 带上本地 group_id', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await seedBook('01B1', groupId: group.groupId);
      final meta = await library.buildLocalMeta(
        '01B1',
        rev: 2,
        deviceId: '01DEVA000000000000',
        deviceName: '设备A',
        now: DateTime.fromMillisecondsSinceEpoch(5000),
      );
      expect(meta.groupId, group.groupId);
      expect(meta.toJson()['groupId'], group.groupId);
    });

    test('applyRemoteMeta 应用远端 group_id（本地分组存在时）', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await seedBook('01B1');
      await library.applyRemoteMeta(bookMeta('01B1', groupId: group.groupId));
      expect((await db.booksDao.getById('01B1'))!.groupId, group.groupId);
    });

    test('远端 group_id 本地不存在 → 不写悬空外键（视为未分组）', () async {
      await seedBook('01B1');
      await library.applyRemoteMeta(bookMeta('01B1', groupId: '01UNKNOWN'));
      expect((await db.booksDao.getById('01B1'))!.groupId, isNull);
    });

    test('远端 meta 无分组 → 本地归未分组', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await seedBook('01B1', groupId: group.groupId);
      await library.applyRemoteMeta(bookMeta('01B1'));
      expect((await db.booksDao.getById('01B1'))!.groupId, isNull);
    });
  });

  group('远端分组 meta 的应用（applyRemoteGroup）', () {
    test('远端新分组 → 本地建组（名称/排序）', () async {
      await library.applyRemoteGroup(
        groupMeta('01G1', name: '长篇', sortOrder: 3),
      );
      final row = await db.bookGroupsDao.groupById('01G1');
      expect(row, isNotNull);
      expect(row!.name, '长篇');
      expect(row.sortOrder, 3);
      expect(row.deleted, isFalse);
    });

    test('远端改名 → 本地改名（排序同步）', () async {
      await library.applyRemoteGroup(
        groupMeta('01G1', name: '小说', sortOrder: 1),
      );
      await library.applyRemoteGroup(
        groupMeta('01G1', name: '长篇', sortOrder: 5, rev: 2),
      );
      final row = await db.bookGroupsDao.groupById('01G1');
      expect(row!.name, '长篇');
      expect(row.sortOrder, 5);
    });

    test('远端墓碑 → 本地分组消失、组内书回到未分组（不丢书）', () async {
      await library.applyRemoteGroup(groupMeta('01G1', name: '小说'));
      await seedBook('01B1', groupId: '01G1');
      await library.applyRemoteGroup(groupMeta('01G1', deleted: true, rev: 2));
      expect(await db.bookGroupsDao.groupById('01G1'), isNull);
      final book = await db.booksDao.getById('01B1');
      expect(book, isNotNull, reason: '删分组不丢书');
      expect(book!.groupId, isNull, reason: '组内书回到未分组');
    });
  });

  group('同名分组合并（名称级去重，docs/05 §2.1）', () {
    test('mergeLocalGroup：书籍外键迁移到规范分组，源分组行删除', () async {
      await library.applyRemoteGroup(groupMeta('01G1', name: '小说'));
      await seedBook('01B1', groupId: '01G1');
      await library.mergeLocalGroup(
        fromGroupId: '01G1',
        toGroupId: '01G2',
        toName: '小说',
        toSortOrder: 0,
      );
      // 目标分组行新建，源分组行删除。
      expect(await db.bookGroupsDao.groupById('01G1'), isNull);
      expect(await db.bookGroupsDao.groupById('01G2'), isNotNull);
      // 书籍外键迁到规范分组。
      expect((await db.booksDao.getById('01B1'))!.groupId, '01G2');
    });

    test('mergeLocalGroup：目标分组已存在时保留其名称', () async {
      await library.applyRemoteGroup(groupMeta('01G1', name: '小说'));
      await library.applyRemoteGroup(
        groupMeta('01G2', name: '小说', sortOrder: 7),
      );
      await seedBook('01B1', groupId: '01G1');
      await library.mergeLocalGroup(
        fromGroupId: '01G1',
        toGroupId: '01G2',
        toName: '小说',
        toSortOrder: 0,
      );
      final row = await db.bookGroupsDao.groupById('01G2');
      expect(row!.name, '小说');
      expect(row.sortOrder, 7);
      expect((await db.booksDao.getById('01B1'))!.groupId, '01G2');
    });
  });

  group('dirty 判定（未推送的本地修改）', () {
    test('书籍换组 → 该书 dirty（group_id 进 meta）', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await seedBook('01B1');
      // 先落一次同步状态（上次同步 = 未分组）。
      await db
          .into(db.syncState)
          .insert(
            SyncStateCompanion.insert(
              bookId: '01B1',
              backendKey: 'webdav',
              baseRev: 1,
              lastSyncedAt: 1000,
              lastSyncedMetaJson: Value(bookMeta('01B1').toJsonString()),
            ),
          );
      var snap = (await library.listBooks()).single;
      expect(snap.dirty, isFalse, reason: '分组未变 → 不脏');

      await db.booksDao.setGroup('01B1', group.groupId);
      snap = (await library.listBooks()).single;
      expect(snap.dirty, isTrue, reason: '换组 → 需重推 meta');
      expect(snap.meta!.groupId, group.groupId);
    });

    test('分组改名 → 该分组 dirty；未改则不脏', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await db
          .into(db.groupSyncState)
          .insert(
            GroupSyncStateCompanion.insert(
              groupId: group.groupId,
              backendKey: 'webdav',
              baseRev: 1,
              lastSyncedAt: 1000,
              lastSyncedGroupJson: Value(
                groupMeta(group.groupId).toJsonString(),
              ),
            ),
          );
      var snap = (await library.listGroups()).single;
      expect(snap.dirty, isFalse);

      await db.bookGroupsDao.renameGroup(group.groupId, '长篇');
      snap = (await library.listGroups()).single;
      expect(snap.dirty, isTrue, reason: '改名 → 需重推分组 meta');
      expect(snap.name, '长篇');
    });

    test('本地软删分组 → 快照标记 deleted（待推墓碑）', () async {
      final group = await db.bookGroupsDao.createGroup('小说');
      await db.bookGroupsDao.deleteGroup(group.groupId);
      final snap = (await library.listGroups()).single;
      expect(snap.deleted, isTrue);
      expect(snap.name, '小说', reason: '墓碑仍需名称与排序信息');
    });
  });
}
