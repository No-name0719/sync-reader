import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';
import '../support/memory_webdav_server.dart';

/// WebDavAdapter 专属单测：错误映射总表（docs/04 §8.4 / backend_adapter.dart
/// 错误约定）、能力探测与降级、两级清单（stub.rev 缓存）、幂等与凭据安全。
void main() {
  late MemoryWebDavServer server;
  late WebDavAdapter adapter;
  late Directory tempDir;

  const root = '/Apps/SyncReader';

  Future<WebDavAdapter> connectedAdapter({
    MemoryWebDavServer? on,
    String? password,
    String? rootPath,
  }) async {
    final target = on ?? server;
    final a = WebDavAdapter();
    await a.connect(
      BackendConfig(
        kind: BackendKind.webdav,
        baseUrl: target.uri.toString(),
        username: target.username,
        password: password ?? target.password,
        rootPath: rootPath ?? root,
      ),
    );
    return a;
  }

  int metaGetCount() => server.countRequests(
    (r) => r.startsWith('GET $root/meta/') && r.endsWith('.json'),
  );

  setUp(() async {
    server = await MemoryWebDavServer.start();
    addTearDown(server.close);
    tempDir = await Directory.systemTemp.createTemp('sync_core_webdav');
    addTearDown(() => tempDir.delete(recursive: true));
    adapter = await connectedAdapter();
  });

  Future<(File, String)> tempFile(String name, List<int> bytes) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return (file, contentHashOf(bytes));
  }

  group('connect 与错误映射（backend_adapter.dart 错误总表）', () {
    test('全新网盘（根不存在）：PROPFIND 404 不报错，留给 ensureLayout', () async {
      // setUp 的 server 即全新：connect 已成功。
      expect(await adapter.readLibraryJson(), isNull);
    });

    test('401 → AuthFailed（密码错误引导重新授权）', () async {
      await expectLater(
        connectedAdapter(password: 'wrong-pass'),
        throwsA(isA<AuthFailed>()),
      );
    });

    test('403 → AuthFailed（引导检查应用密码目录权限）', () async {
      server.failNext('PROPFIND', 403);
      final a = WebDavAdapter();
      await expectLater(
        a.connect(
          BackendConfig(
            kind: BackendKind.webdav,
            baseUrl: server.uri.toString(),
            username: server.username,
            password: server.password,
          ),
        ),
        throwsA(isA<AuthFailed>()),
      );
    });

    test('连接目标不可达 → BackendRequestException(statusCode: null)', () async {
      // 先占一个端口再关掉：得到"确定无人监听"的端口。
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = socket.port;
      await socket.close();

      final a = WebDavAdapter(connectTimeout: const Duration(seconds: 3));
      await expectLater(
        a.connect(
          BackendConfig(
            kind: BackendKind.webdav,
            baseUrl: 'http://127.0.0.1:$deadPort',
            username: 'x',
            password: 'y',
          ),
        ),
        throwsA(
          isA<BackendRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    });

    test('429 + Retry-After（秒数）→ statusCode 429 且 retryAfter 解析', () async {
      await adapter.ensureLayout();
      server.failNext('PUT', 429, headers: {'retry-after': '7'});
      await expectLater(
        adapter.putMeta(buildMeta(bookId: bookIdOf(1), rev: 1), expectedRev: 0),
        throwsA(
          isA<BackendRequestException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 7),
              ),
        ),
      );
    });

    test('503 + Retry-After（HTTP 日期）→ retryAfter ≈ 日期差', () async {
      await adapter.ensureLayout();
      final at = DateTime.now().toUtc().add(const Duration(seconds: 5));
      server.failNext(
        'PROPFIND',
        503,
        headers: {'retry-after': HttpDate.format(at)},
      );
      await expectLater(
        adapter.listMetas(),
        throwsA(
          isA<BackendRequestException>()
              .having((e) => e.statusCode, 'statusCode', 503)
              .having(
                (e) => e.retryAfter?.inMilliseconds,
                'retryAfter',
                allOf(greaterThan(2000), lessThan(7000)),
              ),
        ),
      );
    });

    test('500 → statusCode 500、retryAfter null（5xx 可重试类）', () async {
      await adapter.ensureLayout();
      server.failNext('GET', 500);
      await expectLater(
        adapter.getMeta(bookIdOf(1)),
        throwsA(
          isA<BackendRequestException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.retryAfter, 'retryAfter', isNull),
        ),
      );
    });

    test('403 于写路径同样映射 AuthFailed（权限类不重试）', () async {
      await adapter.ensureLayout();
      server.failNext('PUT', 403);
      await expectLater(
        adapter.putMeta(buildMeta(bookId: bookIdOf(1), rev: 1), expectedRev: 0),
        throwsA(isA<AuthFailed>()),
      );
    });

    test('异常 message 不含密码、不含查询串（凭据安全 NFR-03）', () async {
      await adapter.ensureLayout();
      server.failNext('PUT', 503);
      try {
        await adapter.putMeta(
          buildMeta(bookId: bookIdOf(1), rev: 1),
          expectedRev: 0,
        );
        fail('应当抛出');
      } on BackendRequestException catch (e) {
        expect(e.message, isNot(contains(server.password)));
        expect(e.message, isNot(contains('?')));
      }
      expect(adapter.toString(), isNot(contains(server.password)));
    });
  });

  group('ensureLayout 与 library.json', () {
    test('幂等：目录 405 视为存在；library.json 不被覆盖', () async {
      await adapter.ensureLayout();
      final first = await adapter.readLibraryJson();
      await adapter.ensureLayout();
      final second = await adapter.readLibraryJson();
      expect(second, same(first), reason: '两次读取同一实例（缓存语义）');
      expect(server.exists('$root/meta'), isTrue);
      expect(server.exists('$root/books'), isTrue);
      expect(server.exists('$root/tmp'), isTrue);
    });

    test('他端写入的 libraryId 不被破坏（已存在且可解析则不覆盖）', () async {
      server.seedFile(
        '$root/library.json',
        utf8.encode(
          jsonEncode({
            'schemaVersion': 1,
            'libraryId': '01HISLIBRARY000000000',
            'createdAt': '2026-01-01T00:00:00.000Z',
          }),
        ),
      );
      await adapter.ensureLayout();
      final lib = await adapter.readLibraryJson();
      expect(lib, contains('01HISLIBRARY000000000'));
    });

    test('损坏的 library.json → 重写为可解析内容', () async {
      server.seedFile('$root/library.json', utf8.encode('{broken json'));
      await adapter.ensureLayout();
      final lib = await adapter.readLibraryJson();
      expect(lib, contains('libraryId'));
    });

    test('通用服务器无 /Apps/ 预留：逐级建父目录', () async {
      final a = await connectedAdapter(rootPath: '/Deep/Nested/Sync');
      await a.ensureLayout();
      expect(server.exists('/Deep'), isTrue);
      expect(server.exists('/Deep/Nested/Sync/meta'), isTrue);
    });

    test('自定义 rootPath 含空格/中文：逐段编码后可用', () async {
      final a = await connectedAdapter(rootPath: '/我的 同步/阅读');
      await a.ensureLayout();
      await a.putMeta(buildMeta(bookId: bookIdOf(1), rev: 1), expectedRev: 0);
      expect(
        (await a.listMetas()).stubs[bookIdOf(1)]!.rev,
        1,
        reason: '编码后读写一致',
      );
      expect(server.exists('/我的 同步/阅读/meta'), isTrue);
    });
  });

  group('两级清单（stub.rev 权威值，见 WebDavAdapter 类注释）', () {
    test('putMeta 回填缓存：同实例 listMetas 零补拉 GET', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 3),
        expectedRev: 0,
      );
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(2), rev: 7),
        expectedRev: 0,
      );
      final before = metaGetCount();
      final listing = await adapter.listMetas();
      expect(listing.stubs[bookIdOf(1)]!.rev, 3);
      expect(listing.stubs[bookIdOf(2)]!.rev, 7);
      expect(metaGetCount() - before, 0, reason: 'PUT 响应 ETag 已回填缓存');
    });

    test('冷缓存（新实例）：每本补拉一次 GET；再列零 GET', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 3),
        expectedRev: 0,
      );
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(2), rev: 7),
        expectedRev: 0,
      );

      final cold = await connectedAdapter();
      final before = metaGetCount();
      final listing = await cold.listMetas();
      expect(listing.stubs[bookIdOf(1)]!.rev, 3, reason: 'rev 为权威值');
      expect(listing.stubs[bookIdOf(2)]!.rev, 7);
      expect(metaGetCount() - before, 2, reason: '冷缓存逐本补拉恰一次');
      expect(
        listing.stubs[bookIdOf(1)]!.etag,
        isNotNull,
        reason: '契约要求 stub 必带 etag',
      );

      await cold.listMetas();
      expect(metaGetCount() - before, 2, reason: '热缓存零补拉');
    });

    test('他端变更只补拉变更本（etag 失效的那一本）', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1),
        expectedRev: 0,
      );
      await adapter.listMetas(); // 缓存 b1

      // 他端推进 b1 → rev3；b2 全新上架。
      server.seedFile(
        '$root/meta/${bookIdOf(1)}.json',
        utf8.encode(buildMeta(bookId: bookIdOf(1), rev: 3).toJsonString()),
      );
      server.seedFile(
        '$root/meta/${bookIdOf(2)}.json',
        utf8.encode(buildMeta(bookId: bookIdOf(2), rev: 1).toJsonString()),
      );

      final before = metaGetCount();
      final listing = await adapter.listMetas();
      expect(metaGetCount() - before, 2, reason: 'b1 etag 失效 + b2 未知，各补拉一次');
      expect(listing.stubs[bookIdOf(1)]!.rev, 3);
      expect(listing.stubs[bookIdOf(2)]!.rev, 1);
    });

    test('损坏的 meta：stub.rev 退化为 0，不阻塞其余条目', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1),
        expectedRev: 0,
      );
      server.seedFile('$root/meta/${bookIdOf(2)}.json', utf8.encode('garbage'));

      final listing = await adapter.listMetas();
      expect(listing.stubs[bookIdOf(1)]!.rev, 1);
      expect(listing.stubs[bookIdOf(2)]!.rev, 0);
      // 后续 getMeta 抛 FormatException → 引擎转 Corruption（docs/05 §6）。
      await expectLater(
        adapter.getMeta(bookIdOf(2)),
        throwsA(isA<FormatException>()),
      );
    });

    test('PROPFIND 前缀 D: 与无前缀命名空间均可解析', () async {
      for (final prefix in const ['D', '']) {
        final s = await MemoryWebDavServer.start(propfindPrefix: prefix);
        addTearDown(s.close);
        final a = await connectedAdapter(on: s);
        await a.ensureLayout();
        await a.putMeta(buildMeta(bookId: bookIdOf(1), rev: 5), expectedRev: 0);
        final listing = await a.listMetas();
        expect(listing.stubs[bookIdOf(1)]!.rev, 5, reason: '前缀 $prefix');
        expect(listing.stubs[bookIdOf(1)]!.etag, isNotNull);
      }
    });
  });

  group('能力探测与降级（docs/04 §8.1）', () {
    test('完整服务器：MOVE/ETag/Range 全部支持且结果缓存', () async {
      await adapter.ensureLayout();
      final caps = await adapter.probeCapabilities();
      expect(caps.supportsMove, isTrue);
      expect(caps.supportsEtag, isTrue);
      expect(caps.supportsRange, isTrue);
      expect(server.childrenOf('$root/tmp'), isEmpty, reason: '探测文件已清理');
      expect(
        identical(caps, await adapter.probeCapabilities()),
        isTrue,
        reason: '实例级缓存',
      );
    });

    test('无 ETag + 禁 MOVE：降级能力（etag=false、move=false、range=true）', () async {
      final s = await MemoryWebDavServer.start(
        enableEtag: false,
        enableMove: false,
      );
      addTearDown(s.close);
      final a = await connectedAdapter(on: s);
      await a.ensureLayout();
      final caps = await a.probeCapabilities();
      expect(caps.supportsMove, isFalse);
      expect(caps.supportsEtag, isFalse);
      expect(caps.supportsRange, isTrue);
      expect(s.childrenOf('$root/tmp'), isEmpty);
    });

    test('无 ETag：etag 用 synthetic-{size}-{mtime} 合成，对引擎透明', () async {
      final s = await MemoryWebDavServer.start(enableEtag: false);
      addTearDown(s.close);
      final a = await connectedAdapter(on: s);
      await a.ensureLayout();
      await a.putMeta(buildMeta(bookId: bookIdOf(1), rev: 1), expectedRev: 0);
      final stub = (await a.listMetas()).stubs[bookIdOf(1)]!;
      expect(stub.etag, startsWith('synthetic-'));
      expect(stub.etag, isNotNull);
      // 同一文件再次列出 etag 稳定（同一 mtime/size）。
      final again = (await a.listMetas()).stubs[bookIdOf(1)]!;
      expect(again.etag, stub.etag);
    });
  });

  group('uploadBook（docs/04 §5.3 / docs/05 §1 原子性）', () {
    test('MOVE 原子提交：tmp 暂存后迁移到位，暂存区清空', () async {
      await adapter.ensureLayout();
      final bytes = deterministicBytes(128, 3);
      final (file, hash) = await tempFile('a.epub', bytes);
      await adapter.uploadBook(bookIdOf(1), file, hash);
      expect(server.fileBytes('$root/books/${bookIdOf(1)}.epub'), bytes);
      expect(server.childrenOf('$root/tmp'), isEmpty, reason: '.part 已迁移');
    });

    test('本地文件哈希与声明不符 → ContentHashMismatch 且零网络请求', () async {
      await adapter.ensureLayout();
      final (file, _) = await tempFile('a.txt', [1, 2, 3]);
      final before = server.methodCount('PUT');
      await expectLater(
        adapter.uploadBook(bookIdOf(1), file, contentHashOf([9, 9, 9])),
        throwsA(isA<ContentHashMismatch>()),
      );
      expect(server.methodCount('PUT') - before, 0);
    });

    test('远端同内容（etag=MD5 的网盘）：免下载判定直接跳过', () async {
      await adapter.ensureLayout();
      final bytes = deterministicBytes(64, 11);
      final md5hex = md5.convert(bytes).toString();
      server.seedFile('$root/books/${bookIdOf(1)}.txt', bytes, etag: md5hex);
      final (file, hash) = await tempFile('a.txt', bytes);
      final before = server.methodCount('PUT');
      await adapter.uploadBook(bookIdOf(1), file, hash);
      expect(server.methodCount('PUT') - before, 0, reason: '幂等跳过');
      expect(
        server.countRequests((r) => r.startsWith('GET $root/books/')),
        0,
        reason: 'MD5 etag 判同：免下载比对',
      );
    });

    test('远端 etag=MD5 但内容不同 → 免下载直接报 ContentHashMismatch', () async {
      await adapter.ensureLayout();
      final bytes = deterministicBytes(64, 11);
      server.seedFile('$root/books/${bookIdOf(1)}.txt', [
        1,
        2,
        3,
      ], etag: md5.convert([9, 9, 9]).toString());
      final (file, hash) = await tempFile('a.txt', bytes);
      await expectLater(
        adapter.uploadBook(bookIdOf(1), file, hash),
        throwsA(isA<ContentHashMismatch>()),
      );
      expect(
        server.countRequests((r) => r.startsWith('GET $root/books/')),
        0,
        reason: 'MD5 etag 判异：无需下载',
      );
    });

    test('远端同尺寸不同内容（sha etag）→ 下载比对后报 ContentHashMismatch', () async {
      await adapter.ensureLayout();
      server.seedFile('$root/books/${bookIdOf(1)}.txt', [1, 2, 3, 4]);
      final (file, hash) = await tempFile('a.txt', [5, 6, 7, 8]);
      await expectLater(
        adapter.uploadBook(bookIdOf(1), file, hash),
        throwsA(isA<ContentHashMismatch>()),
      );
      expect(server.fileBytes('$root/books/${bookIdOf(1)}.txt'), [
        1,
        2,
        3,
        4,
      ], reason: '远端内容不被覆盖');
    });

    test('无 MOVE 降级：直写目标位 + 尺寸校验通过', () async {
      final s = await MemoryWebDavServer.start(enableMove: false);
      addTearDown(s.close);
      final a = await connectedAdapter(on: s);
      await a.ensureLayout();
      final bytes = deterministicBytes(200, 12);
      final (file, hash) = await tempFile('b.pdf', bytes);
      await a.uploadBook(bookIdOf(1), file, hash);
      expect(s.fileBytes('$root/books/${bookIdOf(1)}.pdf'), bytes);
      expect(s.childrenOf('$root/tmp'), isEmpty);
      expect(s.methodCount('MOVE'), 1, reason: '仅能力探测尝试过一次 MOVE');
      // 幂等：无 ETag 服务器走下载比对路径跳过（上传直写，无 MOVE）。
      await a.uploadBook(bookIdOf(1), file, hash);
      expect(s.methodCount('MOVE'), 1);
    });
  });

  group('downloadBook / deleteMeta', () {
    test('云端正文不存在 → BackendRequestException(statusCode: 404)', () async {
      await adapter.ensureLayout();
      await expectLater(
        adapter.downloadBook(bookIdOf(1)).toList(),
        throwsA(
          isA<BackendRequestException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('startByte 越过 EOF → 空流（与内存实现 clamp 语义一致）', () async {
      await adapter.ensureLayout();
      final (file, hash) = await tempFile('a.txt', [1, 2, 3, 4, 5]);
      await adapter.uploadBook(bookIdOf(1), file, hash);
      final flat = await adapter
          .downloadBook(bookIdOf(1), startByte: 5)
          .expand((c) => c)
          .toList();
      expect(flat, isEmpty);
    });

    test('服务器不支持 Range（200 全量）→ 本地切片语义不变', () async {
      final s = await MemoryWebDavServer.start(enableRange: false);
      addTearDown(s.close);
      final a = await connectedAdapter(on: s);
      await a.ensureLayout();
      final bytes = deterministicBytes(100, 9);
      final (file, hash) = await tempFile('book.txt', bytes);
      await a.uploadBook(bookIdOf(1), file, hash);
      final flat = await a
          .downloadBook(bookIdOf(1), startByte: 40)
          .expand((c) => c)
          .toList();
      expect(flat, bytes.sublist(40));
    });

    test('downloadBook 免扩展名探测：常见扩展名直查 + 未知扩展名清单兜底', () async {
      await adapter.ensureLayout();
      // 常见扩展名：直接命中 'pdf'。
      final bytes = deterministicBytes(20, 1);
      final (file, hash) = await tempFile('a.pdf', bytes);
      await adapter.uploadBook(bookIdOf(1), file, hash);
      expect(
        await adapter.downloadBook(bookIdOf(1)).expand((c) => c).toList(),
        bytes,
      );

      // 自由扩展名（.mobi）：候选未命中 → PROPFIND books/ 前缀匹配。
      final exotic = await tempFile('b.mobi', [7, 8, 9]);
      await adapter.uploadBook(bookIdOf(2), exotic.$1, exotic.$2);
      expect(
        await adapter.downloadBook(bookIdOf(2)).expand((c) => c).toList(),
        [7, 8, 9],
      );
    });

    test('deleteMeta 幂等：404 视为成功', () async {
      await adapter.ensureLayout();
      await adapter.deleteMeta(bookIdOf(1)); // 不存在 → 不抛
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1),
        expectedRev: 0,
      );
      await adapter.deleteMeta(bookIdOf(1));
      expect(await adapter.getMeta(bookIdOf(1)), isNull);
    });
  });

  group('putMeta / putTombstone 写前重读（WebDAV 无 CAS）', () {
    test('远端落后/领先判定与远端副本携带', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 2),
        expectedRev: 0,
      );
      // expectedRev 与远端不符 → RevConflict（含远端副本）。
      await expectLater(
        adapter.putMeta(buildMeta(bookId: bookIdOf(1), rev: 3), expectedRev: 1),
        throwsA(
          isA<RevConflict>()
              .having((e) => e.remoteRev, 'remoteRev', 2)
              .having((e) => e.remoteMeta?.rev, 'remoteMeta.rev', 2),
        ),
      );
    });

    test('putTombstone 拒绝非 tombstone meta（与内存参考实现一致）', () async {
      await adapter.ensureLayout();
      await expectLater(
        adapter.putTombstone(
          buildMeta(bookId: bookIdOf(1), rev: 1),
          expectedRev: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('成功写入后远端 ETag 回填缓存：写后立即 listMetas 无补拉', () async {
      await adapter.ensureLayout();
      await adapter.putMeta(
        buildMeta(bookId: bookIdOf(1), rev: 1),
        expectedRev: 0,
      );
      // getMeta 也回填缓存（重读/304 之外的完整读取路径）。
      await adapter.getMeta(bookIdOf(1));
      final before = metaGetCount();
      await adapter.listMetas();
      expect(metaGetCount() - before, 0);
    });
  });
}
