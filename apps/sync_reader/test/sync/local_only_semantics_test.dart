/// v1.1 重设计批 1（数据层）验收场景测试：
/// A19 删除语义变更 + A21/A22「仅本地 / 未上传」状态。
///
/// 覆盖任务书的 5 条验收场景：
/// 1. 本地删除 → **书移出书库**（books 行删除、进度级联清除）
///    → 同步**不**把它推回云端 → 墓碑正常上云；
/// 2. 导入时选「不上传」→ 全量同步后云端无此书 → 手动「上传到云端」后
///    正常上架（云端有 meta + 正文被上传）；
/// 3. 「从云端移除」→ 云端 meta 消失 → 本地保留且可读 → 不会被重新推上去；
/// 4. 仅本地书读了之后，进度不会被推上云；
/// 5. 两端删除同一本书后收敛一致（tombstone 幂等：本端已有墓碑时收到远端
///    墓碑，不覆盖本地记账）；
/// 6. 场景 6（2026-11-18 用户实测反馈）：云端 + 本地都删除后，书库里
///    **不再出现**该书（旧实现留下一条「未下载」残影，永久显示）。
///
/// 夹具：内存 drift 库 + InMemoryAdapter（sync_core 内存参考实现）+
/// 临时目录文件存储；真实 IO 不涉及（正文文件用临时目录真文件）。
library;

import 'dart:convert';
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
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

import '../library/fake_handler.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late InMemoryAdapter adapter;
  late DriftSyncStore store;
  late DriftLocalLibrary library;
  late Directory tmpDir;
  late BookFileStore fileStore;
  late SyncFacade facade;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    await credentials.save(SecureKeys.webdavAccount, 'u@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    adapter = InMemoryAdapter();
    store = DriftSyncStore(db: db, credentials: credentials);
    tmpDir = await Directory.systemTemp.createTemp('syncr_local_only');
    fileStore = BookFileStore(tmpDir);
    await fileStore.ensureLayout();
    library = DriftLocalLibrary(db: db, fileStore: Future.value(fileStore));
    facade = SyncFacade(
      adapterProvider: _FixedAdapterProvider(adapter),
      credentials: credentials,
      store: store,
      library: library,
      db: db,
      readPreferences: () async => const SyncPreferencesSnapshot(),
      onOutcome: (_) {},
    );
  });

  tearDown(() async {
    await facade.dispose();
    await db.close();
    if (tmpDir.existsSync()) await tmpDir.delete(recursive: true);
  });

  /// 造一本本地书（真实正文文件落在 store 布局内）。
  Future<String> seedLocalBook({
    String title = '本地书',
    String content = 'hello local only',
    bool withProgress = false,
  }) async {
    final bookId = '01BOOK${DateTime.now().microsecondsSinceEpoch}';
    final path = fileStore.resolveBookPath(bookId, 'txt');
    final file = File(path);
    await file.create(recursive: true);
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
        localPath: Value(path),
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

  group('场景 1：本地删除（docs/10 §4.7b）', () {
    test('书移出书库 + 正文删盘 + 墓碑上云 + 同步不推回云端', () async {
      final bookId = await seedLocalBook(withProgress: true);
      // 首次同步：正常上架。
      final first = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(first!.success, isTrue);
      expect(adapter.metas.containsKey(bookId), isTrue);

      // 本地删除：删正文/封面 + 移出书库（books 行删除）+ 写墓碑。
      await db.booksDao.deleteBook(
        bookId,
        removeFiles: fileStore.deleteBookFiles,
      );
      // 书已从书库移除（回归：删除后不该再以「未下载」残影留在书库里）。
      expect(await db.booksDao.getById(bookId), isNull);
      // 进度随书级联清除。
      expect(await db.progressDao.getByBookId(bookId), isNull);
      expect(await db.booksDao.hasTombstone(bookId), isTrue);
      // 正文文件真删盘。
      expect(
        File(fileStore.resolveBookPath(bookId, 'txt')).existsSync(),
        isFalse,
      );

      // 推 tombstone 到云端（详情页删除流程的同一动作）：本地行已删，
      // 墓碑内容取自 sync_state 的上次同步副本，仍能正常上云。
      final deleted = await facade.deleteBook(bookId);
      expect(deleted!.success, isTrue);
      expect(
        BookMeta.fromJsonString(adapter.metas[bookId]!).isTombstone,
        isTrue,
      );

      // 下次全量同步：**不**把它当正常书推回云端（云端仍是墓碑）。
      final second = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(second!.success, isTrue);
      expect(
        BookMeta.fromJsonString(adapter.metas[bookId]!).isTombstone,
        isTrue,
        reason: '本地已删除的书不得被推回云端（否则与墓碑打架）',
      );
      // 本地也不复活（books 行不重建）。
      expect(await db.booksDao.getById(bookId), isNull);
    });

    test('被删除的书不参与 diff（listBooks 排除墓碑书）', () async {
      final bookId = await seedLocalBook();
      await facade.fullSync(source: SyncTriggerSource.manual);
      await db.booksDao.deleteBook(bookId);
      // 快照里不应再出现这本书。
      final snapshots = await library.listBooks();
      expect(
        snapshots.where((s) => s.bookId == bookId),
        isEmpty,
        reason: '有墓碑的书不参与 diff（docs/10 §4.7b 实施要点 2）',
      );
    });
  });

  group('场景 2：导入时选「不上传」（docs/10 §4.7c）', () {
    /// 用真实导入服务导入一个 txt 文件（假 handler 解析元数据）。
    Future<String> importTxt({required bool uploadToCloud}) async {
      final source = File('${tmpDir.path}/导入测试.txt');
      await source.writeAsString('导入正文内容', flush: true);
      final service = BookImportService(
        booksDao: db.booksDao,
        registry: FormatRegistry()..register(FakeHandler()),
        fileStore: Future.value(fileStore),
        localOnlyDao: db.localOnlyBooksDao,
      );
      final summary = await service.importFiles([
        source.path,
      ], uploadToCloud: uploadToCloud);
      expect(summary.imported, hasLength(1));
      return summary.imported.single.bookId;
    }

    test('不上传：全量同步后云端无此书；「上传到云端」后正常上架', () async {
      final bookId = await importTxt(uploadToCloud: false);
      // 本地标记为仅本地。
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);

      // 全量同步：云端没有这本书（既不推 meta 也不传正文）。
      final report = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(report!.success, isTrue);
      expect(adapter.metas.containsKey(bookId), isFalse);
      expect(adapter.contentOf(bookId), isNull);
      expect(report.decisions.containsKey(bookId), isFalse);

      // 手动「上传到云端」：解除标记 + 清 baseRev → 走 diff 第 7a 行上架。
      final ok = await facade.uploadToCloud(bookId);
      expect(ok, isTrue);
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isFalse);
      // 云端有 meta + 正文已上传。
      expect(adapter.metas.containsKey(bookId), isTrue);
      final meta = BookMeta.fromJsonString(adapter.metas[bookId]!);
      expect(meta.isTombstone, isFalse);
      expect(meta.book.contentHash, isNotEmpty);
      expect(adapter.contentOf(bookId), isNotNull);
    });

    test('默认勾选（上传）：导入后照常自动上架', () async {
      final bookId = await importTxt(uploadToCloud: true);
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isFalse);
      final report = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(report!.success, isTrue);
      expect(adapter.metas.containsKey(bookId), isTrue);
    });

    test('重复导入：勾选状态落到已有书上（勾选→解除标记 / 取消→写标记）', () async {
      final bookId = await importTxt(uploadToCloud: false);
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);

      // 再次导入同一文件且勾选「上传」→ 解除已有书的仅本地标记。
      final source = File('${tmpDir.path}/导入测试.txt');
      final service = BookImportService(
        booksDao: db.booksDao,
        registry: FormatRegistry()..register(FakeHandler()),
        fileStore: Future.value(fileStore),
        localOnlyDao: db.localOnlyBooksDao,
      );
      final again = await service.importFiles([
        source.path,
      ], uploadToCloud: true);
      expect(again.imported, isEmpty);
      expect(again.duplicates, hasLength(1));
      expect(
        await db.localOnlyBooksDao.isLocalOnly(bookId),
        isFalse,
        reason: '勾选「上传」时已有书的仅本地标记应被解除',
      );

      // 再来一次「不上传」→ 写回标记。
      await service.importFiles([source.path], uploadToCloud: false);
      expect(await db.localOnlyBooksDao.isLocalOnly(bookId), isTrue);
    });
  });

  group('场景 3：「从云端移除」（docs/10 §4.7c / §4.8）', () {
    test('云端 meta 消失 + 本地保留可读 + 不会被重新推上去', () async {
      final bookId = await seedLocalBook(title: '要移除的书');
      await facade.fullSync(source: SyncTriggerSource.manual);
      expect(adapter.metas.containsKey(bookId), isTrue);
      final localPath = fileStore.resolveBookPath(bookId, 'txt');
      expect(File(localPath).existsSync(), isTrue);

      // 「从云端移除」：只删云端副本，不写 tombstone。
      final ok = await facade.removeFromCloud(bookId);
      expect(ok, isTrue);
      expect(adapter.metas.containsKey(bookId), isFalse);
      // 未写墓碑（不是全局删除）。
      expect(await db.booksDao.hasTombstone(bookId), isFalse);
      // 本地保留且可读。
      final book = await db.booksDao.getById(bookId);
      expect(book, isNotNull);
      expect(book!.localPath, isNotNull);
      expect(File(localPath).existsSync(), isTrue);
      expect(File(localPath).readAsStringSync(), 'hello local only');

      // 下次全量同步：baseRev 保持 → 落 diff 第 7b 行（云端缺失），
      // 不再上传（云端仍无此书）。
      final report = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(report!.success, isTrue);
      expect(report.decisions[bookId], SyncDecision.cloudMissing);
      expect(adapter.metas.containsKey(bookId), isFalse);
      // 云端正文永不删除（docs/04 §7.1 不变式）：只剩一个无 meta 引用的
      // 云端孤儿文件，由「云端孤儿清理」工具按需清理。
      expect(adapter.contentOf(bookId), isNotNull);
      // 本地依旧可读。
      expect(File(localPath).existsSync(), isTrue);
    });

    test('未配置同步时安全 no-op（返回 false，不抛异常）', () async {
      final empty = SyncFacade(
        adapterProvider: _FixedAdapterProvider(adapter),
        credentials: InMemoryCredentialStore(),
        store: store,
        library: library,
        db: db,
        readPreferences: () async => const SyncPreferencesSnapshot(),
        onOutcome: (_) {},
      );
      expect(await empty.removeFromCloud('01X'), isFalse);
      expect(await empty.uploadToCloud('01X'), isFalse);
      await empty.dispose();
    });
  });

  group('场景 6：云端 + 本地都删除（用户实测反馈，2026-11-18）', () {
    test('「从云端移除」后本地再删：书库中不再出现该书', () async {
      final bookId = await seedLocalBook(title: '两边都删的书');
      await facade.fullSync(source: SyncTriggerSource.manual);
      expect(adapter.metas.containsKey(bookId), isTrue);

      // ① 云端移除：云端 meta 消失，本地副本保留。
      expect(await facade.removeFromCloud(bookId), isTrue);
      expect(adapter.metas.containsKey(bookId), isFalse);
      expect(await db.booksDao.getById(bookId), isNotNull);

      // ② 本地删除：移出书库（books 行删除）+ 正文删盘 + 写墓碑。
      await db.booksDao.deleteBook(
        bookId,
        removeFiles: fileStore.deleteBookFiles,
      );
      expect(await db.booksDao.getById(bookId), isNull);
      expect(await db.booksDao.readAllBookIds(), isNot(contains(bookId)));
      expect(await db.booksDao.hasTombstone(bookId), isTrue);
      expect(
        File(fileStore.resolveBookPath(bookId, 'txt')).existsSync(),
        isFalse,
      );

      // ③ 推墓碑：云端本就没有该书（已移除）→ 只记账本，不再造云端条目。
      final report = await facade.deleteBook(bookId);
      expect(report!.success, isTrue);
      expect(adapter.metas.containsKey(bookId), isFalse);
      final ledger = await store.tombstoneLedger();
      expect(ledger.single.bookId, bookId);
      expect(ledger.single.pushed, isTrue);

      // ④ 下次全量同步：书不会回来（本地无行、云端无 meta）。
      final sync = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(sync!.success, isTrue);
      expect(await db.booksDao.getById(bookId), isNull);
      expect(adapter.metas.containsKey(bookId), isFalse);
    });

    test('本地先删、再从云端移除：同样不会在书库留下残影', () async {
      final bookId = await seedLocalBook(title: '先删后移除');
      await facade.fullSync(source: SyncTriggerSource.manual);

      // 本地删除 → 墓碑上云（云端 meta 变墓碑）。
      await db.booksDao.deleteBook(
        bookId,
        removeFiles: fileStore.deleteBookFiles,
      );
      final report = await facade.deleteBook(bookId);
      expect(report!.success, isTrue);
      expect(
        BookMeta.fromJsonString(adapter.metas[bookId]!).isTombstone,
        isTrue,
      );
      expect(await db.booksDao.getById(bookId), isNull);

      // 云端那侧再移除（墓碑文件被删）→ 本地依旧没有这本书。
      await facade.removeFromCloud(bookId);
      final sync = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(sync!.success, isTrue);
      expect(await db.booksDao.getById(bookId), isNull);
    });
  });

  group('场景 4：仅本地书的进度不被推上云', () {
    test('pushBookMeta 对仅本地书是 no-op（云端无此书）', () async {
      final bookId = await seedLocalBook(withProgress: true);
      await db.localOnlyBooksDao.markLocalOnly(bookId);
      // 读进度（脏标记）后触发单书推送。
      final report = await facade.pushBookMeta(bookId);
      expect(report, isNull, reason: '仅本地书不推送');
      expect(adapter.metas.containsKey(bookId), isFalse);
      // 云端确实没有这本书的 meta（进度也无从谈起）。
      expect(adapter.getMetaCalls >= 0, isTrue);
      expect(adapter.metas.keys, isNot(contains(bookId)));
    });

    test('仅本地书不参与 diff（全量同步也不推）', () async {
      final bookId = await seedLocalBook(withProgress: true);
      await db.localOnlyBooksDao.markLocalOnly(bookId);
      final snapshots = await library.listBooks();
      expect(snapshots.where((s) => s.bookId == bookId), isEmpty);
      final report = await facade.fullSync(source: SyncTriggerSource.manual);
      expect(report!.success, isTrue);
      expect(adapter.metas.containsKey(bookId), isFalse);
    });
  });

  group('场景 5：两端删除同一本书后收敛一致（tombstone 幂等）', () {
    test('本端已有墓碑时收到远端墓碑：幂等（不覆盖本地记账）', () async {
      final bookId = await seedLocalBook();
      await facade.fullSync(source: SyncTriggerSource.manual);
      // 本端删除：移出书库 + 墓碑入账。
      await db.booksDao.deleteBook(bookId);
      final localTombstone = (await db.select(db.deletedBooks).getSingle());
      expect(localTombstone.pushed, isFalse);

      // 收到远端墓碑（同一本书、别的设备也删了）→ 幂等：不覆盖已有的
      // deletedAt / pushed / contentHash（`pushed=false` 是"待推墓碑"的
      // 记账，覆盖成 true 会让离线删除的墓碑永远推不出去）。
      final remoteMeta = BookMeta(
        schemaVersion: kCurrentSchemaVersion,
        bookId: bookId,
        rev: 99,
        deviceId: 'other-device',
        deviceName: '其他设备',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        deleted: true,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        book: BookInfo(
          title: '本地书',
          author: '',
          format: 'txt',
          fileName: '本地书.txt',
          contentHash: 'sha256:other',
          sizeBytes: 1,
          tocFingerprint: 'tfp:0000000000000000',
        ),
        reading: ReadingStats(
          totalSeconds: 0,
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await library.applyRemoteMeta(remoteMeta);

      expect(await db.booksDao.getById(bookId), isNull);
      final tombstone = (await db.select(db.deletedBooks).getSingle());
      expect(tombstone.deletedAt, localTombstone.deletedAt);
      expect(tombstone.pushed, localTombstone.pushed);
      expect(tombstone.contentHash, localTombstone.contentHash);
    });

    test('本端墓碑在账 + books 行又出现（墓碑没推上去、书被别端改活）→ 收到墓碑时收走', () async {
      final bookId = await seedLocalBook();
      await facade.fullSync(source: SyncTriggerSource.manual);
      // 本端删除：移出书库 + 墓碑入账（待推，pushed=false）。
      await db.booksDao.deleteBook(bookId);
      expect(await db.booksDao.getById(bookId), isNull);

      // 墓碑没推上去，而别的设备把书改活并推了正常 meta → 本端拉活会重建
      // books 行（占位书，localPath=NULL）。
      final liveMeta = BookMeta(
        schemaVersion: kCurrentSchemaVersion,
        bookId: bookId,
        rev: 50,
        deviceId: 'other-device',
        deviceName: '其他设备',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        book: BookInfo(
          title: '被改活的书',
          author: '',
          format: 'txt',
          fileName: '本地书.txt',
          contentHash: 'sha256:live',
          sizeBytes: 1,
          tocFingerprint: 'tfp:0000000000000000',
        ),
        reading: ReadingStats(
          totalSeconds: 0,
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await library.applyRemoteMeta(liveMeta);
      expect(await db.booksDao.getById(bookId), isNotNull);

      // 墓碑随后回来 → books 行必须被收走（否则书库里留下复活残影）。
      final remoteTombstone = BookMeta(
        schemaVersion: kCurrentSchemaVersion,
        bookId: bookId,
        rev: 51,
        deviceId: 'other-device',
        deviceName: '其他设备',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        deleted: true,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        book: BookInfo(
          title: '被改活的书',
          author: '',
          format: 'txt',
          fileName: '本地书.txt',
          contentHash: 'sha256:live',
          sizeBytes: 1,
          tocFingerprint: 'tfp:0000000000000000',
        ),
        reading: ReadingStats(
          totalSeconds: 0,
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await library.applyRemoteMeta(remoteTombstone);
      expect(await db.booksDao.getById(bookId), isNull);
      // 本地待推记账不被覆盖（pushed 仍是 false）。
      final ledger = await db.select(db.deletedBooks).getSingle();
      expect(ledger.pushed, isFalse);
    });

    test('本端未发起的删除（其它设备删的）：沿用既有语义删 books 行', () async {
      final bookId = await seedLocalBook();
      await facade.fullSync(source: SyncTriggerSource.manual);
      // 本端无墓碑 → 收到远端墓碑时按既有行为移出书库视图。
      final remoteMeta = BookMeta(
        schemaVersion: kCurrentSchemaVersion,
        bookId: bookId,
        rev: 99,
        deviceId: 'other-device',
        deviceName: '其他设备',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        deleted: true,
        deletedAt: DateTime.fromMillisecondsSinceEpoch(9999),
        book: BookInfo(
          title: '本地书',
          author: '',
          format: 'txt',
          fileName: '本地书.txt',
          contentHash: 'sha256:other',
          sizeBytes: 1,
          tocFingerprint: 'tfp:0000000000000000',
        ),
        reading: ReadingStats(
          totalSeconds: 0,
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
      );
      await library.applyRemoteMeta(remoteMeta);
      expect(await db.booksDao.getById(bookId), isNull);
      final tombstone = (await db.select(db.deletedBooks).getSingle());
      expect(tombstone.bookId, bookId);
      expect(tombstone.pushed, isTrue);
    });
  });
}

/// 真实 SHA-256（`sha256:<hex>`）。
String _sha256(String content) =>
    'sha256:${sha256.convert(utf8.encode(content)).toString()}';

/// 固定适配器供应（测试注入）。
class _FixedAdapterProvider implements SyncAdapterProvider {
  const _FixedAdapterProvider(this.adapter);

  final BackendAdapter adapter;

  @override
  BackendAdapter create(BackendConfig config) => adapter;
}
