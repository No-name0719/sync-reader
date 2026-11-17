/// 分组云端同步的 app 层双端验收（FR-107，docs/05 §2.1）：
/// A 端建组 + 归组书籍 → B 端同步后看到同名分组与同一批书；
/// A 端改名 → B 端跟随；A 端删组 → B 端分组消失且书回未分组。
///
/// 夹具：两个内存 drift 库（各自 DriftLocalLibrary + DriftSyncStore）+
/// 共享同一 [InMemoryAdapter]（sync_core 内存参考实现）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';

void main() {
  late AppDatabase dbA;
  late AppDatabase dbB;
  late DriftSyncStore storeA;
  late DriftSyncStore storeB;
  late DriftLocalLibrary libraryA;
  late DriftLocalLibrary libraryB;
  late InMemoryAdapter cloud;
  late Directory tmpDir;
  var now = DateTime.utc(2026, 11, 17, 8);

  SyncEngine buildEngine({
    required SyncStore store,
    required DriftLocalLibrary library,
    required String deviceId,
    required String deviceName,
  }) {
    final transfer = TransferQueue(
      adapter: cloud,
      retryPolicy: const RetryPolicy(),
      delay: (_) async {},
    );
    return SyncEngine(
      adapter: cloud,
      store: store,
      library: library,
      transfer: transfer,
      now: () => now,
      identity: () async => (deviceId: deviceId, deviceName: deviceName),
      backendKey: 'webdav',
    );
  }

  setUp(() async {
    dbA = AppDatabase.forTesting(NativeDatabase.memory());
    dbB = AppDatabase.forTesting(NativeDatabase.memory());
    await dbA.customSelect('SELECT 1').getSingle();
    await dbB.customSelect('SELECT 1').getSingle();
    tmpDir = await Directory.systemTemp.createTemp('syncr_group_2dev');
    final fileStore = BookFileStore(tmpDir);
    await fileStore.ensureLayout();
    storeA = DriftSyncStore(db: dbA, credentials: InMemoryCredentialStore());
    storeB = DriftSyncStore(db: dbB, credentials: InMemoryCredentialStore());
    libraryA = DriftLocalLibrary(db: dbA, fileStore: Future.value(fileStore));
    libraryB = DriftLocalLibrary(db: dbB, fileStore: Future.value(fileStore));
    cloud = InMemoryAdapter();
    await cloud.connect(
      const BackendConfig(kind: BackendKind.webdav, baseUrl: 'memory://cloud'),
    );
    now = DateTime.utc(2026, 11, 17, 8);
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
    await tmpDir.delete(recursive: true);
  });

  /// 在 A 端造一本书（带正文文件，供上云）。
  Future<void> seedBookOnA(String bookId) async {
    final content = '$bookId-content'.codeUnits;
    final file = File('${tmpDir.path}/$bookId.src')..writeAsBytesSync(content);
    final hash = 'sha256:${sha256.convert(content)}';
    await dbA.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: '书$bookId',
        format: 'txt',
        fileName: '$bookId.txt',
        contentHash: hash,
        sizeBytes: content.length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1,
        localPath: Value(file.path),
      ),
    );
  }

  test('A 建组归组 → B 同步后同名分组与书籍归属一致；改名跟随；删组回未分组', () async {
    final engineA = buildEngine(
      store: storeA,
      library: libraryA,
      deviceId: '01DEVAAAA0000000000',
      deviceName: '设备A',
    );
    final engineB = buildEngine(
      store: storeB,
      library: libraryB,
      deviceId: '01DEVBBBB0000000000',
      deviceName: '设备B',
    );

    // ── A 端：建组「小说」+ 把书拖进分组 ──
    final group = await dbA.bookGroupsDao.createGroup('小说');
    await seedBookOnA('01BOOK0000000000000A');
    await dbA.booksDao.setGroup('01BOOK0000000000000A', group.groupId);

    now = now.add(const Duration(minutes: 1));
    final reportA = await engineA.fullSync();
    expect(reportA.success, isTrue, reason: '${reportA.results}');
    expect(reportA.groupDecisions[group.groupId], SyncDecision.localNewPush);

    // ── B 端同步：出现同名分组 + 书在该分组里 ──
    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');
    final groupsOnB = await dbB.bookGroupsDao.allGroups();
    expect(groupsOnB, hasLength(1));
    expect(groupsOnB.single.name, '小说');
    final bookOnB = await dbB.booksDao.getById('01BOOK0000000000000A');
    expect(bookOnB, isNotNull);
    expect(bookOnB!.groupId, groupsOnB.single.groupId);

    // ── A 端改名 → B 端跟随 ──
    await dbA.bookGroupsDao.renameGroup(group.groupId, '长篇');
    now = now.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();
    expect((await dbB.bookGroupsDao.allGroups()).single.name, '长篇');

    // ── A 端删组 → B 端分组消失、书回未分组（不丢书）──
    await dbA.bookGroupsDao.deleteGroup(group.groupId);
    now = now.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();
    expect(await dbB.bookGroupsDao.allGroups(), isEmpty);
    final bookAfterDelete = await dbB.booksDao.getById('01BOOK0000000000000A');
    expect(bookAfterDelete, isNotNull, reason: '删分组不丢书');
    expect(bookAfterDelete!.groupId, isNull, reason: '组内书回到未分组');
  });

  test('B 端已有同名分组 → 同步后合并成一个（名称级去重）', () async {
    final engineA = buildEngine(
      store: storeA,
      library: libraryA,
      deviceId: '01DEVAAAA0000000000',
      deviceName: '设备A',
    );
    final engineB = buildEngine(
      store: storeB,
      library: libraryB,
      deviceId: '01DEVBBBB0000000000',
      deviceName: '设备B',
    );

    // 两端各自建了同名分组「小说」。
    final groupA = await dbA.bookGroupsDao.createGroup('小说');
    await dbB.bookGroupsDao.createGroup('小说');
    await seedBookOnA('01BOOK0000000000000A');
    await dbA.booksDao.setGroup('01BOOK0000000000000A', groupA.groupId);

    now = now.add(const Duration(minutes: 1));
    await engineA.fullSync();
    now = now.add(const Duration(minutes: 1));
    await engineB.fullSync();

    // B 同步时把本地同名分组并入云端那条 → 只剩一个「小说」。
    now = now.add(const Duration(minutes: 1));
    final reportB = await engineB.fullSync();
    expect(reportB.success, isTrue, reason: '${reportB.results}');
    final groupsOnB = await dbB.bookGroupsDao.allGroups();
    expect(groupsOnB, hasLength(1), reason: '同名分组必须合并成一个');
    expect(groupsOnB.single.name, '小说');
    // A 的书在 B 端也落在同一个分组里。
    final bookOnB = await dbB.booksDao.getById('01BOOK0000000000000A');
    expect(bookOnB!.groupId, groupsOnB.single.groupId);
  });
}
