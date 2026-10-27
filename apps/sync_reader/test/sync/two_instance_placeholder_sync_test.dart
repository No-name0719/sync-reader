/// C1.3 双实例端到端集成（drift 内存库 + WebDavAdapter + 内存 WebDAV 服务器）：
/// 实例 A 导入 → 全量上架 → 实例 B 全量拉到占位书 → 点开下载（门面路径）→
/// SHA-256 校验通过 → 正文可读。
///
/// 这是"书库刷新含占位书"（FR-402/404）的自动化替身：books 列表/进度徽标
/// 的 drift watch 流以本测试断言的表数据为唯一事实源；一次性详情 provider
/// 的失效接线由 syncFacadeProvider.onOutcome 完成（`report != null` 时
/// invalidate bookDetailProvider），widget 层行为另有 library/detail 页测试覆盖。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

import 'support/memory_webdav_server.dart';

void main() {
  late MemoryWebDavServer server;
  late Directory tmpA;
  late Directory tmpB;
  late _Instance a;
  late _Instance b;

  setUp(() async {
    server = await MemoryWebDavServer.start();
    tmpA = await Directory.systemTemp.createTemp('syncr_two_a');
    tmpB = await Directory.systemTemp.createTemp('syncr_two_b');
    a = await _Instance.create('A', server, tmpA);
    b = await _Instance.create('B', server, tmpB);
  });

  tearDown(() async {
    await a.dispose();
    await b.dispose();
    await server.close();
    await tmpA.delete(recursive: true);
    await tmpB.delete(recursive: true);
  });

  /// 实例 A 导入一本本地书（真实文件 + drift 行 + 进度）。
  Future<({String bookId, File file, String content})> importOnA({
    String title = '双端书',
    String content = 'hello two-instance sync',
  }) async {
    final bookId = generateUlid();
    final file = File('${tmpA.path}/src-$bookId.txt');
    await file.writeAsString(content, flush: true);
    await a.db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: title,
        format: 'txt',
        fileName: '$title.txt',
        contentHash:
            'sha256:${sha256.convert(utf8.encode(content)).toString()}',
        sizeBytes: utf8.encode(content).length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value(file.path),
      ),
    );
    await a.db.progressDao.upsert(
      bookId: bookId,
      locatorJson: jsonEncode({'type': 'raw', 'ratio': 0.4}),
      percent: 0.4,
      dirty: true,
    );
    return (bookId: bookId, file: file, content: content);
  }

  test('导入 → 同步 → 第二实例拉到占位 → 下载 → hash 校验通过 → 可读', () async {
    final imported = await importOnA();

    // A 全量：新书上架（meta + 正文）。
    final reportA = await a.facade.fullSync(source: SyncTriggerSource.manual);
    expect(reportA!.success, isTrue, reason: '${reportA.results}');

    // B 全量：云端书以占位形态出现（书库刷新事实源：books 行 localPath 为空）。
    final reportB = await b.facade.fullSync(source: SyncTriggerSource.manual);
    expect(reportB!.success, isTrue, reason: '${reportB.results}');
    final rowOnB = await b.db.booksDao.getById(imported.bookId);
    expect(rowOnB, isNotNull);
    expect(rowOnB!.localPath, isNull, reason: '占位书：正文未下载');
    expect(rowOnB.title, '双端书');

    // B 点开占位书 → 门面 downloadPlaceholder（FR-402 的 UI 调用路径）。
    final ok = await b.facade.downloadPlaceholder(imported.bookId);
    expect(ok, isTrue);
    final after = await b.db.booksDao.getById(imported.bookId);
    expect(after!.localPath, isNotNull, reason: '下载完成 → 书库刷新 → 可打开');

    // 正文可读 + hash 校验通过（TransferQueue 下载校验 + 本地重算双保险）。
    final downloaded = File(after.localPath!);
    expect(await downloaded.readAsString(), imported.content);
    final digest = sha256.convert(await downloaded.readAsBytes()).toString();
    expect(after.contentHash, 'sha256:$digest');

    // 书库刷新后 B 的列表事实源含该书且不再是占位。
    final booksOnB = await b.db.select(b.db.books).get();
    final refreshed = booksOnB.firstWhere((e) => e.bookId == imported.bookId);
    expect((refreshed.localPath ?? '').isNotEmpty, isTrue);
  });

  test('下载失败不丢占位：云端正文缺失 → 占位保持、可重试不崩溃', () async {
    final imported = await importOnA();
    final reportA = await a.facade.fullSync(source: SyncTriggerSource.manual);
    expect(reportA!.success, isTrue);

    // 模拟云端正文丢失（仅 meta 在）：B 拉到占位后下载必失败。
    server.removeFile('/Apps/SyncReader/books/${imported.bookId}.txt');
    final reportB = await b.facade.fullSync(source: SyncTriggerSource.manual);
    expect(reportB!.success, isTrue, reason: 'meta 仍在，拉取成功');

    final ok = await b.facade.downloadPlaceholder(imported.bookId);
    expect(ok, isFalse, reason: '云端正文 404 → Corruption → 下载失败');
    final row = await b.db.booksDao.getById(imported.bookId);
    expect(row!.localPath, isNull, reason: '失败不丢占位（FR-402）');
    // 失败文案上报（书级错误 → 状态源）。
    expect(b.outcomes.last.failureText, isNotNull);
  });
}

/// 一台"设备"：独立 drift 内存库 + 文件目录 + 默认装配门面（WebDAV 工厂）。
class _Instance {
  _Instance._(
    this.name,
    this.db,
    this.credentials,
    this.tmpDir,
    this.facade,
    this.outcomes,
  );

  final String name;
  final AppDatabase db;
  final InMemoryCredentialStore credentials;
  final Directory tmpDir;
  final SyncFacade facade;
  final List<SyncStatusOutcome> outcomes;

  static Future<_Instance> create(
    String name,
    MemoryWebDavServer server,
    Directory tmpDir,
  ) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final credentials = InMemoryCredentialStore();
    final outcomes = <SyncStatusOutcome>[];
    final facade = SyncFacade(
      adapterProvider: const WebDavSyncAdapterProvider(),
      credentials: credentials,
      store: DriftSyncStore(
        db: db,
        credentials: credentials,
        backendKey: 'webdav',
      ),
      library: DriftLocalLibrary(
        db: db,
        fileStore: Future.value(BookFileStore(tmpDir)),
        backendKey: 'webdav',
      ),
      readPreferences: () async => const SyncPreferencesSnapshot(),
      onOutcome: outcomes.add,
    );
    final instance = _Instance._(
      name,
      db,
      credentials,
      tmpDir,
      facade,
      outcomes,
    );
    await instance._configure(server);
    return instance;
  }

  Future<void> _configure(MemoryWebDavServer server) async {
    await credentials.save(SecureKeys.webdavAccount, server.username);
    await credentials.save(SecureKeys.webdavPassword, server.password);
    await credentials.save(SecureKeys.webdavBaseUrl, server.uri.toString());
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
  }

  Future<void> dispose() async {
    await facade.dispose();
    await db.close();
  }
}
