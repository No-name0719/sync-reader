/// Phase C 适配器接线测试：`syncAdapterProvider` 默认供应 WebDavAdapter。
///
/// 覆盖（C1.1）：
/// - Riverpod 默认装配解析出的 SyncAdapterProvider 是 WebDAV 工厂；
/// - 工厂创建的适配器 kind 为 webdav、可对真实 HTTP 语义完成 connect；
/// - 未配置凭据：门面 fullSync/pushBookMeta/downloadPlaceholder 安全 no-op
///   并报告 unconfigured，不崩溃不误同步（FR-405）；
/// - 凭据齐全：默认装配（WebDAV 工厂）经内存 WebDAV 服务器完成一次全量
///   同步收敛（真实 HTTP 栈：PROPFIND/PUT/GET/MOVE）；
/// - resetEngine 闭环：换凭据（新服务器）→ 引擎丢弃，下次同步以新配置重建。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_local_library.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

import 'support/memory_webdav_server.dart';

void main() {
  test('默认 syncAdapterProvider 供应 WebDAV 工厂（Phase C 切换点）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final provider = container.read(syncAdapterProvider);
    expect(provider, isA<WebDavSyncAdapterProvider>());
    // 工厂产出 WebDAV 适配器（connect 由下一用例覆盖）。
    expect(
      provider.create(
        BackendConfig(
          kind: BackendKind.webdav,
          baseUrl: 'http://127.0.0.1:1',
          username: 'u',
          password: 'p',
        ),
      ),
      isA<WebDavAdapter>(),
    );
  });

  test('WebDavSyncAdapterProvider 工厂：创建 WebDAV 适配器并连通', () async {
    final server = await MemoryWebDavServer.start();
    addTearDown(server.close);
    const provider = WebDavSyncAdapterProvider();
    final config = _configOf(server);
    final adapter = provider.create(config);
    expect(adapter.kind, BackendKind.webdav);
    await adapter.connect(config);
    // 连通后 ensureLayout 可建目录（真实 HTTP）。
    await adapter.ensureLayout();
    expect(server.exists('/Apps/SyncReader/meta'), isTrue);
    await adapter.dispose();
  });

  test('未配置凭据：默认装配 fullSync/pushBookMeta/downloadPlaceholder no-op', () async {
    final env = await _Env.create();
    addTearDown(env.dispose);
    // 不写凭据。
    final report = await env.facade.fullSync(source: SyncTriggerSource.manual);
    expect(report, isNull);
    expect(env.outcomes.last.stateId, SyncStateId.unconfigured);
    await env.facade.pushBookMeta('whatever');
    expect(env.outcomes.last.stateId, SyncStateId.unconfigured);
    final ok = await env.facade.downloadPlaceholder('no-book');
    expect(ok, isFalse);
    expect(env.outcomes.last.stateId, SyncStateId.unconfigured);
    // 未配置期间不得对服务器发出任何请求。
    expect(env.server.requests, isEmpty);
  });

  test('默认装配 + 内存 WebDAV 服务器：全量同步收敛（真实 HTTP 语义）', () async {
    final env = await _Env.create();
    addTearDown(env.dispose);
    await env.configureAgainstServer();
    final report = await env.facade.fullSync(source: SyncTriggerSource.manual);
    expect(report, isNotNull);
    expect(report!.phaseError, isNull, reason: '${report.phaseError}');
    expect(report.success, isTrue, reason: '${report.results}');
    expect(env.outcomes.last.stateId, SyncStateId.ok);
    // 云端布局已建立（library.json + meta/）。
    expect(env.server.exists('/Apps/SyncReader/library.json'), isTrue);
    expect(env.server.exists('/Apps/SyncReader/meta'), isTrue);
  });

  test('resetEngine 闭环：换服务器（新凭据）后重建适配器并同步成功', () async {
    final env = await _Env.create();
    addTearDown(env.dispose);
    await env.configureAgainstServer();
    var report = await env.facade.fullSync(source: SyncTriggerSource.manual);
    expect(report!.success, isTrue);
    expect(env.facade.engineReady, isTrue);

    // 换一台全新服务器（模拟用户改 baseUrl/换账号后重连）。
    final server2 = await MemoryWebDavServer.start();
    addTearDown(server2.close);
    await env.reconfigure(
      baseUrl: server2.uri.toString(),
      username: server2.username,
      password: server2.password,
    );
    await env.facade.resetEngine();
    expect(env.facade.engineReady, isFalse);

    report = await env.facade.fullSync(source: SyncTriggerSource.manual);
    expect(report, isNotNull);
    // ignore: avoid_print
    print('DEBUG phaseError=${report!.phaseError} results=${report.results}');
    expect(report.success, isTrue, reason: '${report.results}');
    expect(env.facade.engineReady, isTrue);
    // 新服务器上完成了首次全量（布局已建）。
    expect(server2.exists('/Apps/SyncReader/library.json'), isTrue);
  });
}

BackendConfig _configOf(MemoryWebDavServer server) => BackendConfig(
  kind: BackendKind.webdav,
  baseUrl: server.uri.toString(),
  username: server.username,
  password: server.password,
  rootPath: '/Apps/SyncReader',
);

/// 门面 + 内存 WebDAV 服务器的默认装配环境。
///
/// adapterProvider 不做任何注入替身：直接使用 [WebDavSyncAdapterProvider]
/// （与生产 `syncAdapterProvider` 的默认值一致）。
class _Env {
  _Env._(
    this.server,
    this.db,
    this.credentials,
    this.tmpDir,
    this.facade,
    this.outcomes,
  );

  final MemoryWebDavServer server;
  final AppDatabase db;
  final InMemoryCredentialStore credentials;
  final Directory tmpDir;
  final SyncFacade facade;
  final List<SyncStatusOutcome> outcomes;

  static Future<_Env> create() async {
    final server = await MemoryWebDavServer.start();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final credentials = InMemoryCredentialStore();
    final tmpDir = await Directory.systemTemp.createTemp('syncr_wiring');
    final outcomes = <SyncStatusOutcome>[];
    final facade = SyncFacade(
      adapterProvider: const WebDavSyncAdapterProvider(),
      credentials: credentials,
      store: DriftSyncStore(db: db, credentials: credentials),
      library: DriftLocalLibrary(
        db: db,
        fileStore: Future.value(BookFileStore(tmpDir)),
      ),
      readPreferences: () async => const SyncPreferencesSnapshot(),
      onOutcome: outcomes.add,
    );
    return _Env._(server, db, credentials, tmpDir, facade, outcomes);
  }

  Future<void> configureAgainstServer() async {
    await credentials.save(SecureKeys.webdavAccount, server.username);
    await credentials.save(SecureKeys.webdavPassword, server.password);
    await credentials.save(SecureKeys.webdavBaseUrl, server.uri.toString());
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
  }

  Future<void> reconfigure({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    await credentials.save(SecureKeys.webdavBaseUrl, baseUrl);
    await credentials.save(SecureKeys.webdavAccount, username);
    await credentials.save(SecureKeys.webdavPassword, password);
  }

  Future<void> dispose() async {
    await facade.dispose();
    await db.close();
    await tmpDir.delete(recursive: true);
  }
}
