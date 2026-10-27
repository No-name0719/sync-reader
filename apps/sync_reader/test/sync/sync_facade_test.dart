/// 同步门面端到端测试（B2 引擎路径）：InMemoryAdapter + drift 内存库驱动。
/// 覆盖：未配置 no-op（unconfigured）、配置后手动全量收敛、进度推送、
/// 占位书下载、云端删除应用（tombstone 移出书库视图）、状态上报。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late InMemoryAdapter adapter;
  late DriftSyncStore store;
  late DriftLocalLibrary library;
  late Directory tmpDir;
  late List<SyncStatusOutcome> outcomes;
  late SyncFacade facade;
  var prefs = const SyncPreferencesSnapshot();

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    adapter = InMemoryAdapter();
    store = DriftSyncStore(db: db, credentials: credentials);
    tmpDir = await Directory.systemTemp.createTemp('syncr_facade');
    library = DriftLocalLibrary(
      db: db,
      fileStore: Future.value(BookFileStore(tmpDir)),
    );
    outcomes = [];
    facade = SyncFacade(
      adapterProvider: _FixedAdapterProvider(adapter),
      credentials: credentials,
      store: store,
      library: library,
      readPreferences: () async => prefs,
      onOutcome: outcomes.add,
    );
  });

  tearDown(() async {
    await facade.dispose();
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  Future<String> importLocalBook({
    required String title,
    String content = 'hello sync',
    bool withProgress = false,
  }) async {
    final bookId = generateUlid();
    final file = File('${tmpDir.path}/$bookId.txt');
    await file.writeAsString(content, flush: true);
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: title,
        format: 'txt',
        fileName: '$title.txt',
        contentHash: _sha256(content),
        sizeBytes: content.length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value(file.path),
      ),
    );
    if (withProgress) {
      await db.progressDao.upsert(
        bookId: bookId,
        locatorJson: jsonEncode({'type': 'raw', 'ratio': 0.25}),
        percent: 0.25,
        dirty: true,
      );
    }
    return bookId;
  }

  /// 填充云端远端书（他端上架形态：投喂 meta + 正文）。
  Future<String> seedCloudBook({String ratio = '0.75'}) async {
    final bookId = generateUlid();
    final meta = BookMeta(
      schemaVersion: kCurrentSchemaVersion,
      bookId: bookId,
      rev: 1,
      deviceId: 'other-device',
      deviceName: '其他设备',
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      book: BookInfo(
        title: '云端书',
        author: '',
        format: 'txt',
        fileName: 'cloud.txt',
        contentHash: _sha256('cloud content'),
        sizeBytes: 13,
        tocFingerprint: 'tfp:0000000000000000',
      ),
      progress: ReadingProgress(
        locator: RawLocator(ratio: double.parse(ratio)),
        percent: double.parse(ratio),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
      reading: ReadingStats(
        totalSeconds: 60,
        lastReadAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    );
    adapter.putContent(bookId, 'txt', utf8.encode('cloud content'));
    await adapter.putMeta(meta, expectedRev: 0);
    return bookId;
  }

  test('未配置：fullSync/pushBookMeta 安全 no-op 并报告 unconfigured', () async {
    final report = await facade.fullSync(source: SyncTriggerSource.appStart);
    expect(report, isNull);
    expect(outcomes.last.stateId, SyncStateId.unconfigured);
    await facade.pushBookMeta('whatever');
    expect(outcomes.last.stateId, SyncStateId.unconfigured);
  });

  test('配置后手动全量：本地新书上架 + 云端新书占位 + 状态 ok', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final localId = await importLocalBook(title: '本地书');
    final cloudId = await seedCloudBook();

    final report = await facade.fullSync(source: SyncTriggerSource.manual);
    expect(report, isNotNull);
    // 调试可见性：任何阶段/逐书失败都在断言前展示。
    if (!report!.success) {
      // ignore: avoid_print
      print('phaseError=${report.phaseError} results=${report.results}');
    }
    expect(report.phaseError, isNull);
    expect(report.success, isTrue);
    expect(outcomes.last.stateId, SyncStateId.ok);
    expect(outcomes.last.lastSyncedAt, isNotNull);

    // 本地书已上架（云端 meta 存在且 rev ≥ 1）。
    expect(adapter.metas.containsKey(localId), isTrue);
    // 云端书已进本地书库视图（占位：localPath 为空）。
    final cloudRow = await db.booksDao.getById(cloudId);
    expect(cloudRow, isNotNull);
    expect(cloudRow!.localPath, isNull);
    // 同步状态已记录 baseRev。
    final state = await store.syncState(localId, 'webdav');
    expect(state, isNotNull);
    expect(state!.baseRev, greaterThanOrEqualTo(1));
  });

  test('进度变更推送：pushBookMeta 后 dirty 清零、云端 rev 抬升', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final bookId = await importLocalBook(title: '推送书');
    // 首次上架。
    await facade.fullSync(source: SyncTriggerSource.manual);
    final revAfterFirst = (await store.syncState(bookId, 'webdav'))!.baseRev;

    // 产生新进度并直达推送。
    await db.progressDao.upsert(
      bookId: bookId,
      locatorJson: jsonEncode({'type': 'raw', 'ratio': 0.9}),
      percent: 0.9,
      dirty: true,
    );
    final report = await facade.pushBookMeta(bookId);
    expect(report!.success, isTrue);
    final state = await store.syncState(bookId, 'webdav');
    expect(state!.baseRev, greaterThan(revAfterFirst));
    final cloudMeta = await adapter.getMeta(bookId);
    expect(cloudMeta!.progress!.percent, 0.9);
    // 推送结果应用回本地：dirty 清零。
    final progressRow = await db.progressDao.getByBookId(bookId);
    expect(progressRow!.dirty, isFalse);
  });

  test('autoSyncEnabled=false：自动触发 no-op，手动仍执行', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    prefs = const SyncPreferencesSnapshot(autoSyncEnabled: false);
    final auto = await facade.fullSync(source: SyncTriggerSource.periodic);
    expect(auto, isNull);
    final manual = await facade.fullSync(source: SyncTriggerSource.manual);
    expect(manual, isNotNull);
    expect(manual!.success, isTrue);
  });

  test('云端删除：tombstone 应用后移出书库视图并记入账本', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final cloudId = await seedCloudBook();
    // 第一次同步拉入云端书。
    await facade.fullSync(source: SyncTriggerSource.manual);
    expect(await db.booksDao.getById(cloudId), isNotNull);
    // 他端删除：写 tombstone。
    final meta = (await adapter.getMeta(cloudId))!;
    await adapter.putTombstone(
      meta.toTombstone(
        deletedAt: DateTime.fromMillisecondsSinceEpoch(3000),
        deviceId: 'other-device',
        deviceName: '其他设备',
      ),
      expectedRev: meta.rev,
    );
    // 第二次同步应用删除。
    final report = await facade.fullSync(source: SyncTriggerSource.manual);
    expect(report!.success, isTrue);
    expect(await db.booksDao.getById(cloudId), isNull);
    final ledger = await store.tombstoneLedger();
    expect(ledger.map((e) => e.bookId), contains(cloudId));
    // 正文文件保留（本实现不移动文件）。
    expect(adapter.contentOf(cloudId), isNotNull);
  });

  test('本地删除：deleteBook 推 tombstone；本地行已删时经公共祖先回退成功', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final localId = await importLocalBook(title: '要删的书');
    await facade.fullSync(source: SyncTriggerSource.manual);
    expect(adapter.metas.containsKey(localId), isTrue);

    // app 删除顺序：先本地 softDelete，再后台 deleteBook（FR-408）。
    await db.booksDao.softDelete(localId);
    final report = await facade.deleteBook(localId);
    expect(report, isNotNull);
    if (!report!.success) {
      // ignore: avoid_print
      print('phaseError=${report.phaseError} results=${report.results}');
    }
    expect(report.success, isTrue);
    final meta = BookMeta.fromJsonString(adapter.metas[localId]!);
    expect(meta.isTombstone, isTrue);
    final ledger = await store.tombstoneLedger();
    expect(ledger.single.bookId, localId);
    expect(ledger.single.pushed, isTrue);
    // 重复删除幂等：云端已是 tombstone，不再报错。
    final again = await facade.deleteBook(localId);
    expect(again!.success, isTrue);
  });

  test('autoSyncEnabled=false 时删除推送仍执行（用户显式操作不受门控）', () async {
    prefs = const SyncPreferencesSnapshot(autoSyncEnabled: false);
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final localId = await importLocalBook(title: '手动同步才动');
    await facade.fullSync(source: SyncTriggerSource.manual);

    await db.booksDao.softDelete(localId);
    final report = await facade.deleteBook(localId);
    expect(report, isNotNull);
    expect(report!.success, isTrue);
    expect(
      BookMeta.fromJsonString(adapter.metas[localId]!).isTombstone,
      isTrue,
    );
  });

  test('占位书下载：downloadPlaceholder 拉正文并转正', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final cloudId = await seedCloudBook();
    await facade.fullSync(source: SyncTriggerSource.manual);
    final before = await db.booksDao.getById(cloudId);
    expect(before!.localPath, isNull);

    final ok = await facade.downloadPlaceholder(cloudId);
    expect(ok, isTrue);
    final after = await db.booksDao.getById(cloudId);
    expect(after!.localPath, isNotNull);
    expect(File(after.localPath!).readAsStringSync(), 'cloud content');
  });

  test('清除凭据：回未配置态，再次同步 no-op', () async {
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    final config = await facade.readConfig();
    expect(config, isNotNull);
    await facade.clearCredentials();
    expect(credentials.values, isEmpty);
    await facade.fullSync(source: SyncTriggerSource.manual);
    expect(outcomes.last.stateId, SyncStateId.unconfigured);
  });
}

/// 真实 SHA-256（`sha256:<hex>`；TransferQueue 下载校验按真实哈希比对）。
String _sha256(String content) =>
    'sha256:${sha256.convert(utf8.encode(content)).toString()}';

/// 固定适配器供应（测试注入）。
class _FixedAdapterProvider implements SyncAdapterProvider {
  const _FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}
