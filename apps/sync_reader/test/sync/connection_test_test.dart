/// 连接测试服务测试（FR-505）：本地 HttpServer 迷你 WebDAV 桩跑通全套步骤；
/// 401/403/5xx/拒绝连接的分类文案。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/sync/connection_test.dart';

/// 迷你 WebDAV 桩：PROPFIND/MKCOL/PUT/GET/DELETE/MOVE 的最小内存实现。
class _MiniWebDav {
  final Map<String, String> _files = {};
  final Set<String> _dirs = {};
  HttpServer? _server;
  int? _forceStatus;

  /// 注入强制状态码（模拟 401/403/500）。
  void forceStatus(int? status) => _forceStatus = status;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle);
    return 'http://127.0.0.1:${server.port}';
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }

  bool get dirExists => _dirs.isNotEmpty;

  Future<void> _handle(HttpRequest req) async {
    final forced = _forceStatus;
    if (forced != null) {
      req.response.statusCode = forced;
      await req.response.close();
      return;
    }
    final path = req.uri.path;
    switch (req.method) {
      case 'PROPFIND':
        req.response.statusCode =
            _dirs.any((d) => path == d || path.startsWith('$d/'))
            ? 207
            : (path == '/' || path == '/Apps' || path == '/Apps/SyncReader'
                  ? 207
                  : 404);
      case 'MKCOL':
        if (_dirs.contains(path)) {
          req.response.statusCode = 405;
        } else {
          _dirs.add(path);
          req.response.statusCode = 201;
        }
      case 'PUT':
        _files[path] = await utf8.decodeStream(req);
        req.response.statusCode = 201;
      case 'GET':
        final range = req.headers.value('range');
        if (_files.containsKey(path)) {
          req.response.statusCode = 200;
          req.response.headers.set('etag', '"etag-1"');
          if (range != null) {
            // 支持 Range：回 206 + 部分 body。
            req.response.statusCode = 206;
            req.response.add(_files[path]!.codeUnits.take(4).toList());
          } else {
            req.response.write(_files[path]);
          }
        } else {
          req.response.statusCode = 404;
        }
      case 'DELETE':
        final removedFile = _files.remove(path) != null;
        final removedDir = _dirs.remove(path);
        req.response.statusCode = removedFile || removedDir ? 204 : 404;
      case 'MOVE':
        final dest = req.headers.value('destination');
        if (dest == null || !_files.containsKey(path)) {
          req.response.statusCode = 404;
        } else {
          final target = Uri.parse(dest).path;
          _files[target] = _files.remove(path)!;
          req.response.statusCode = 201;
        }
      default:
        req.response.statusCode = 405;
    }
    await req.response.close();
  }
}

void main() {
  late _MiniWebDav stub;
  late String baseUrl;

  setUp(() async {
    stub = _MiniWebDav();
    baseUrl = await stub.start();
  });

  tearDown(() async => stub.stop());

  test('全套步骤通过：延迟逐项记录，能力汇总 MOVE/ETag/Range', () async {
    final result = await ConnectionTester().test(
      baseUrl: baseUrl,
      username: 'user@example.com',
      password: 'app-password-not-logged',
      rootPath: '/Apps/SyncReader',
    );
    expect(result.success, isTrue);
    expect(result.failureText, isNull);
    final names = result.steps.map((s) => s.name).toList();
    expect(names, containsAll(['列目录', '建探针目录', '写探针文件', '读探针文件', 'MOVE 探测']));
    for (final step in result.steps) {
      expect(step.ok, isTrue, reason: '${step.name} 应通过');
      expect(step.latencyMs, isNotNull);
    }
    final caps = result.capabilities;
    expect(caps, isNotNull);
    expect(caps!.supportsMove, isTrue);
    expect(caps.supportsEtag, isTrue);
    expect(caps.supportsRange, isTrue);
    // 桩上确有探针目录（测试后由清理步骤删除，目录集合已清空）。
    expect(stub.dirExists, isFalse);
    // 凭据不进结果文案。
    expect(
      result.steps.map((s) => s.detail ?? '').join(),
      isNot(contains('app-password')),
    );
  });

  test('401 → 密码错误分类文案', () async {
    stub.forceStatus(401);
    final result = await ConnectionTester().test(
      baseUrl: baseUrl,
      username: 'u',
      password: 'p',
    );
    expect(result.success, isFalse);
    expect(result.failureText, contains('密码错误'));
  });

  test('403 → 权限不足分类文案', () async {
    stub.forceStatus(403);
    final result = await ConnectionTester().test(
      baseUrl: baseUrl,
      username: 'u',
      password: 'p',
    );
    expect(result.success, isFalse);
    expect(result.failureText, contains('权限不足'));
  });

  test('5xx → 服务异常分类文案', () async {
    stub.forceStatus(503);
    final result = await ConnectionTester().test(
      baseUrl: baseUrl,
      username: 'u',
      password: 'p',
    );
    expect(result.success, isFalse);
    expect(result.failureText, contains('服务异常'));
  });

  test('连接拒绝 → 网络不可达分类文案', () async {
    // 占用后立即关闭的端口 → 连接被拒。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = server.port;
    await server.close(force: true);
    final result = await ConnectionTester().test(
      baseUrl: 'http://127.0.0.1:$deadPort',
      username: 'u',
      password: 'p',
    );
    expect(result.success, isFalse);
    expect(result.failureText, anyOf(contains('网络'), contains('无法连接')));
  });

  test('joinPath 规范化斜杠', () {
    expect(
      ConnectionTester.joinPath('/Apps/SyncReader', 'probe-1'),
      '/Apps/SyncReader/probe-1',
    );
    expect(
      ConnectionTester.joinPath('/Apps/SyncReader/', '/probe-1'),
      '/Apps/SyncReader/probe-1',
    );
  });
}
