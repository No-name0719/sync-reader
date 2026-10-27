/// 下载占位书 → 封面自动生成 端到端（真实 WebDAV 传输 + 内存服务器 +
/// downloadPlaceholderBook UI 路径）：
/// 实例 A 导入 epub → 全量上架 → 实例 B 全量拉到占位书 → UI 函数触发下载 →
/// 正文落盘后封面经 [CoverGenerator.generateForBook] 补生成并登记 coverPath
/// （drift watch 据此刷新书库，本测试以表数据为事实源）。
///
/// 网络说明：testWidgets 的 fake-async 区内真实 socket 不会完成，所有同步
/// 传输与 IO 等待均包在 `tester.runAsync` 中执行。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/ulid.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/placeholder_download.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

import '../library/fake_handler.dart';
import '../library/support/minimal_epub.dart';
import 'support/memory_webdav_server.dart';

void main() {
  // flutter_test 会把 HttpOverrides.global 换成"一律 400"的 mock（runAsync 也
  // 不豁免）；这里换回透传真实 HttpClient 的 overrides，用完恢复。
  HttpOverrides? originalOverrides;
  setUp(() {
    originalOverrides = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
  });
  tearDown(() {
    HttpOverrides.global = originalOverrides;
  });

  late MemoryWebDavServer? server;
  late Directory tmp;
  late AppDatabase dbA;
  late InMemoryCredentialStore credsA;
  late BookFileStore storeA;
  late BookFileStore storeB;
  late String bookId;

  setUp(() async {
    // 注意：socket 绑定不能在 fake-async 区内做（testWidgets 的 setUp 即在
    // 其中），服务器在本测试体首步经 runAsync 启动。
    server = null;
    tmp = await Directory.systemTemp.createTemp('download_cover_test');
    dbA = AppDatabase.forTesting(NativeDatabase.memory());
    await dbA.customSelect('SELECT 1').getSingle();
    credsA = InMemoryCredentialStore();
    storeA = BookFileStore(Directory('${tmp.path}/a'));
    await storeA.ensureLayout();
    // 实例 B 的文件目录也在 setUp（真实 zone）建好：ensureLayout 的真实 IO
    // 不能进入 testWidgets 的 fake-async 区（会永久挂起）。
    storeB = BookFileStore(Directory('${tmp.path}/b'));
    await storeB.ensureLayout();
    bookId = generateUlid();
  });

  tearDown(() async {
    await server?.close();
    await dbA.close();
    if (tmp.existsSync()) {
      await tmp.delete(recursive: true);
    }
  });

  testWidgets('下载完成后封面文件生成 + coverPath 登记（epub）', (tester) async {
    // 服务器启动（真实 socket，runAsync 内执行）。
    final started = await tester.runAsync(() => MemoryWebDavServer.start());
    if (started == null) {
      fail('内存 WebDAV 服务器未能在 runAsync 内启动');
    }
    server = started;

    // ── 实例 A：导入 epub（真实解析/上架路径与本地导入同布局）────────
    final epubBytes = buildMinimalEpub(coverBytes: tinyPng);
    final sourceFile = File('${tmp.path}/src-$bookId.epub')
      ..writeAsBytesSync(epubBytes);
    await dbA.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: bookId,
        title: '双端封面书',
        format: 'epub',
        fileName: '双端封面书.epub',
        contentHash: 'sha256:${sha256.convert(epubBytes).toString()}',
        sizeBytes: epubBytes.length,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: Value(sourceFile.path),
      ),
    );
    await credsA.save(SecureKeys.webdavAccount, started.username);
    await credsA.save(SecureKeys.webdavPassword, started.password);
    await credsA.save(SecureKeys.webdavBaseUrl, started.uri.toString());
    await credsA.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');

    // ── 实例 B（widget 侧装配）：独立内存库 + 独立文件目录 ───────────
    final dbB = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(dbB.close);
    final credsB = InMemoryCredentialStore();
    await credsB.save(SecureKeys.webdavAccount, started.username);
    await credsB.save(SecureKeys.webdavPassword, started.password);
    await credsB.save(SecureKeys.webdavBaseUrl, started.uri.toString());
    await credsB.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(dbB),
        secureCredentialStoreProvider.overrideWithValue(credsB),
        bookFileStoreProvider.overrideWith((ref) async => storeB),
      ],
    );
    addTearDown(container.dispose);

    // ── A 全量上架 → B 全量拉到占位书（真实传输，runAsync）────────────
    await tester.runAsync(() async {
      final uploader = SyncFacade(
        adapterProvider: const WebDavSyncAdapterProvider(),
        credentials: credsA,
        store: DriftSyncStore(
          db: dbA,
          credentials: credsA,
          backendKey: 'webdav',
        ),
        library: DriftLocalLibrary(
          db: dbA,
          fileStore: Future.value(storeA),
          backendKey: 'webdav',
        ),
        readPreferences: () async => const SyncPreferencesSnapshot(),
        onOutcome: (_) {},
      );
      final reportA = await uploader.fullSync(source: SyncTriggerSource.manual);
      expect(reportA!.success, isTrue, reason: '${reportA.results}');
      await uploader.dispose();

      final reportB = await container
          .read(syncFacadeProvider)
          .fullSync(source: SyncTriggerSource.manual);
      expect(reportB!.success, isTrue, reason: '${reportB.results}');
      final placeholder = await dbB.booksDao.getById(bookId);
      expect(placeholder!.localPath, isNull, reason: '占位书：正文未下载');
      expect(placeholder.coverPath, isNull, reason: '占位书无封面');
    });

    // ── UI 函数触发下载（三个入口的汇聚点；runAsync 内真实 IO）─────────
    // 先 pump 一个挂载好的宿主拿 BuildContext/WidgetRef（Scaffold 提供
    // messenger），再在 runAsync 中调用 downloadPlaceholderBook。
    BuildContext? hostContext;
    WidgetRef? hostRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) {
                hostContext = context;
                hostRef = ref;
                return const Center(child: Text('host'));
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = (await tester.runAsync(() async {
      final result = await downloadPlaceholderBook(
        hostContext!,
        hostRef!,
        bookId: bookId,
        title: '双端封面书',
      );
      expect(result, isTrue, reason: '下载成功');
      // 封面补生成是 unawaited 的旁路：轮询等待落库（真实时间）。
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var current = await dbB.booksDao.getById(bookId);
      while ((current?.coverPath ?? '').isEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        current = await dbB.booksDao.getById(bookId);
      }
      return current;
    }))!;

    expect(row.coverPath, storeB.resolveCoverPath(bookId));
    expect(row.localPath, isNotNull, reason: '正文已下载');
    final coverFile = File(storeB.resolveCoverPath(bookId));
    expect(coverFile.existsSync(), isTrue, reason: '封面文件已落盘');
    expect(coverFile.readAsBytesSync(), tinyPng, reason: 'epub 内嵌封面字节');
  });
}

/// 透传真实 HttpClient（绕开 flutter_test 的 400 mock；仅本套件内生效）。
class _RealHttpOverrides extends HttpOverrides {
  @override
  // 语义上就是"透传"：基类实现返回真实 _HttpClient。
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}
