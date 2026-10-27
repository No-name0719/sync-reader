/// 凭据零落盘测试（FR-504 / NFR-03）：密码值不得出现在 drift 内存库任何表、
/// 任何日志输出中。
///
/// 场景：凭据写入安全存储 + InMemoryAdapter 驱动一轮全量同步后，
/// 扫描 SQLite 全表行与 AppLogger 输出，断言密码值不出现。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/app_logger.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

/// 测试口令（特殊形态便于全文检索）。
const _secret = 'S3cret-AppPassword-#42';
const _account = 'reader@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late InMemoryCredentialStore credentials;
  late DriftSyncStore store;
  late DriftLocalLibrary library;
  late Directory tmpDir;
  late SyncFacade facade;

  /// 捕获全部日志输出（默认脱敏管道之后的内容）。
  final logLines = <String>[];
  final originalDebugPrint = debugPrint;

  setUpAll(() {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logLines.add(message);
    };
  });

  tearDownAll(() {
    debugPrint = originalDebugPrint;
  });

  setUp(() async {
    logLines.clear();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
    store = DriftSyncStore(db: db, credentials: credentials);
    tmpDir = await Directory.systemTemp.createTemp('syncr_redact');
    library = DriftLocalLibrary(
      db: db,
      fileStore: Future.value(BookFileStore(tmpDir)),
    );
    facade = SyncFacade(
      adapterProvider: const InMemorySyncAdapterProvider(),
      credentials: credentials,
      store: store,
      library: library,
      readPreferences: () async => const SyncPreferencesSnapshot(),
      onOutcome: (_) {},
    );
  });

  tearDown(() async {
    await facade.dispose();
    await db.close();
    await tmpDir.delete(recursive: true);
  });

  test('凭据只进安全存储；SQLite 全表与日志不含密码', () async {
    // 模拟向导落凭据。
    await credentials.save(SecureKeys.webdavAccount, _account);
    await credentials.save(SecureKeys.webdavPassword, _secret);
    await credentials.save(
      SecureKeys.webdavBaseUrl,
      'https://dav.example.com/dav/',
    );
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');

    // 本地导入一本书（dirty 进度，可触发推送路径）。
    final bookId = generateUlid();
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: '凭据测试书',
        format: 'txt',
        fileName: 'book.txt',
        contentHash: 'sha256:${'a' * 64}',
        sizeBytes: 3,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value('${tmpDir.path}/book.txt'),
      ),
    );
    await db.progressDao.upsert(
      bookId: bookId,
      locatorJson: jsonEncode({'type': 'raw', 'ratio': 0.5}),
      percent: 0.5,
      dirty: true,
    );

    // 引擎构建 + 全量同步（InMemoryAdapter：配置仅在内存）。
    expect(await facade.readConfig(), isNotNull);
    await facade.fullSync(source: SyncTriggerSource.manual);

    // ── 断言 1：drift 全表扫描不含凭据 ──
    final dumped = StringBuffer();
    for (final table in const [
      'books',
      'progress',
      'sync_state',
      'deleted_books',
      'sync_cursor',
      'reader_settings',
      'sync_queue',
    ]) {
      final rows = await db.customSelect('SELECT * FROM $table').get();
      for (final row in rows) {
        dumped.writeln(jsonEncode(row.data));
      }
    }
    expect(dumped.toString(), isNot(contains(_secret)));
    expect(dumped.toString(), isNot(contains(_account)));

    // ── 断言 2：日志（默认脱敏管道之后）不含密码明文 ──
    final logger = AppLogger();
    logger.info('配置完成 password=$_secret');
    logger.error('同步失败 secret=$_secret', StateError('password=$_secret'));
    final allLogs = logLines.join('\n');
    expect(allLogs, isNot(contains(_secret)));
  });

  test('redactCredentials 覆盖常见凭据键形态', () {
    final redacted = AppLogger.redactCredentials(
      'PUT Authorization: Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ== password=$_secret',
    );
    expect(redacted, isNot(contains(_secret)));
    expect(redacted, isNot(contains('QWxhZGRpbjpvcGVuIHNlc2FtZQ==')));
  });
}
