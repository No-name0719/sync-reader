import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 内存 WebDAV 服务器（离线联调替身，Phase C 复用）。
///
/// `dart:io` HttpServer 绑 127.0.0.1 随机端口，Map 存目录树，实现适配器
/// 所用六动词（PROPFIND/GET/PUT/MOVE/MKCOL/DELETE）的最小 WebDAV 语义：
/// - PROPFIND：Depth 0/1 → 207 multistatus（getetag/getcontentlength/
///   getlastmodified/resourcetype）；[propfindPrefix] 可切换 `d:` / `D:` /
///   无前缀（默认命名空间）三种风格，供适配器解析容错测试；
/// - GET：If-None-Match → 304；Range（a-b / a- / -n）→ 206 + Content-Range，
///   越界 416；[enableEtag]=false 时同时去掉 ETag 头与 getetag 属性，
///   模拟"无 ETag 网盘"（此时 If-None-Match 一律不命中 304）；
///   [enableRange]=false 时忽略 Range 头直接 200 全量（模拟不支持续传）；
/// - PUT：父目录缺失 409、覆盖目录 405、`If-None-Match: *` 存在即 412；
///   [failNext] 故障注入（429/503/5xx + Retry-After，用于错误映射测试）；
/// - MKCOL：已存在 405、父目录缺失 409；
/// - MOVE：[enableMove]=false 时一律 403（模拟禁 MOVE 的网盘）；其余按
///   Destination + Overwrite 语义（源缺失 404、不许覆盖 412、父缺失 409）；
/// - DELETE：文件/目录（递归），缺失 404。
///
/// Basic 认证默认 `webdav / app-pass`，凭据错误/缺失 → 401。
/// 单 isolate 内请求串行处理（无并发竞态）；每次写入的 mtime 单调推进
/// 2s，保证无 ETag 模式下 `synthetic-{size}-{mtime}` 能区分连续两次写入。
class MemoryWebDavServer {
  MemoryWebDavServer._(
    this._server, {
    required this.username,
    required this.password,
    required this.enableEtag,
    required this.enableMove,
    required this.enableRange,
    required this.propfindPrefix,
    required this.propfindMissingStatus,
  });

  static Future<MemoryWebDavServer> start({
    String username = 'webdav',
    String password = 'app-pass',
    bool enableEtag = true,
    bool enableMove = true,
    bool enableRange = true,
    String propfindPrefix = 'd',

    /// PROPFIND 命中缺失资源时返回的状态码（标准 404；坚果云实测 409，
    /// R3 联调画像——用于回归"目录缺失容忍"的适配器行为）。
    int propfindMissingStatus = 404,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = MemoryWebDavServer._(
      server,
      username: username,
      password: password,
      enableEtag: enableEtag,
      enableMove: enableMove,
      enableRange: enableRange,
      propfindPrefix: propfindPrefix,
      propfindMissingStatus: propfindMissingStatus,
    );
    server.listen(instance._enqueue);
    return instance;
  }

  final HttpServer _server;
  final String username;
  final String password;
  final bool enableEtag;
  final bool enableMove;

  /// false 时 GET 忽略 Range 头直接返回 200 全量（模拟不支持断点续传）。
  final bool enableRange;

  /// PROPFIND 缺失资源的状态码（坚果云 409 画像模拟，见 start 注释）。
  final int propfindMissingStatus;

  /// PROPFIND XML 前缀风格：'d' / 'D' / ''（无前缀，默认命名空间）。
  final String propfindPrefix;

  Uri get uri => Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);

  Future<void> close() => _server.close(force: true);

  // ── 存储 ──────────────────────────────────────────────────────────────

  /// 归一化路径（'/' 分隔、已 percent-decode）→ 节点。'/' 为隐式根目录。
  final Map<String, _Node> _store = {};
  int _clockMs = DateTime.utc(2026, 10, 26, 8).millisecondsSinceEpoch;

  DateTime _nextMtime() {
    _clockMs += 2000; // 每次写入推进 2s（> RFC1123 秒级精度）
    return DateTime.fromMillisecondsSinceEpoch(_clockMs, isUtc: true);
  }

  // ── 观测（测试断言用）────────────────────────────────────────────────
  final List<String> requests = [];

  int methodCount(String method) =>
      requests.where((r) => r.startsWith('$method ')).length;

  int countRequests(bool Function(String record) test) =>
      requests.where(test).length;

  void clearRequestLog() => requests.clear();

  // ── 故障注入 ──────────────────────────────────────────────────────────

  final Queue<_Fault> _faults = Queue();

  /// 让接下来 [times] 个 [method] 请求直接返回 [status]（附带 [headers]，
  /// 如 `{'retry-after': '7'}`）。先于鉴权后的业务处理执行。
  void failNext(
    String method,
    int status, {
    int times = 1,
    Map<String, String> headers = const {},
  }) {
    for (var i = 0; i < times; i++) {
      _faults.add(_Fault(method: method, status: status, headers: headers));
    }
  }

  // ── 直插数据（测试播种 / 断言）────────────────────────────────────────

  /// 直接投喂一个文件（自动补父目录；[etag] 缺省为内容 SHA-256 hex）。
  void seedFile(String path, List<int> bytes, {String? etag}) {
    final p = normalizePath(path);
    _ensureParents(p);
    _store[p] = _Node.file(
      Uint8List.fromList(bytes),
      etag: etag ?? sha256.convert(bytes).toString(),
      mtime: _nextMtime(),
    );
  }

  Uint8List? fileBytes(String path) {
    final node = _store[normalizePath(path)];
    return node == null || node.isDir ? null : node.bytes;
  }

  String? etagOf(String path) {
    final node = _store[normalizePath(path)];
    return node == null || node.isDir ? null : node.etag;
  }

  bool exists(String path) {
    final p = normalizePath(path);
    return p == '/' || _store.containsKey(p);
  }

  /// 目录直接子项名（断言 tmp/ 清理、MOVE 结果等）。
  List<String> childrenOf(String dirPath) {
    final dir = normalizePath(dirPath).replaceAll(RegExp(r'/+$'), '');
    return _store.entries
        .where(
          (e) =>
              e.key.startsWith('$dir/') &&
              !e.key.substring(dir.length + 1).contains('/'),
        )
        .map((e) => e.key.substring(dir.length + 1))
        .toList();
  }

  // ── 请求处理（串行化）────────────────────────────────────────────────

  Future<void> _pending = Future<void>.value();

  void _enqueue(HttpRequest request) {
    final run = _pending.then((_) => _handle(request));
    _pending = run.then((_) {}, onError: (Object _, StackTrace _) {});
    // 错误在 _handle 内部已尽力响应；这里兜底防未捕获异常。
    run.catchError((Object _, StackTrace _) async {
      try {
        request.response.statusCode = 500;
        await request.response.close();
      } on StateError {
        // 响应已关闭。
      } on Object {
        // 连接已断。
      }
    });
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add('${request.method} ${request.uri.path}');
    if (!_checkAuth(request)) {
      await _respond(
        request,
        401,
        headers: {'www-authenticate': 'Basic realm="sync-reader"'},
      );
      return;
    }

    _Fault? fault;
    for (final f in _faults) {
      if (f.method == request.method) {
        fault = f;
        break;
      }
    }
    if (fault != null) {
      _faults.remove(fault);
      await _respond(request, fault.status, headers: fault.headers);
      return;
    }

    final body = await _readBody(request);
    final path = normalizePath(request.uri.path);
    switch (request.method) {
      case 'PROPFIND':
        await _propfind(request, path);
      case 'GET':
        await _get(request, path);
      case 'PUT':
        await _put(request, path, body);
      case 'MKCOL':
        await _mkcol(request, path);
      case 'MOVE':
        await _move(request, path);
      case 'DELETE':
        await _delete(request, path);
      default:
        await _respond(request, 405);
    }
  }

  bool _checkAuth(HttpRequest request) {
    final header = request.headers.value('authorization');
    if (header == null) return false;
    final parts = header.split(' ');
    if (parts.length != 2 || parts[0].toLowerCase() != 'basic') return false;
    try {
      final decoded = utf8.decode(base64.decode(parts[1].trim()));
      return decoded == '$username:$password';
    } on FormatException {
      return false;
    }
  }

  Future<void> _propfind(HttpRequest request, String path) async {
    if (path != '/' && !_store.containsKey(path)) {
      await _respond(request, propfindMissingStatus);
      return;
    }
    final depth =
        int.tryParse(request.headers.value('depth')?.trim() ?? '') ?? 0;
    final targets = <(String, _Node)>[];
    final self = _store[path];
    if (path == '/') {
      targets.add(('/', _Node.dir(mtime: _nextMtime())));
    } else if (self != null) {
      targets.add((path, self));
    }
    if (depth >= 1) {
      final dir = path == '/' ? '' : path;
      final children =
          _store.entries
              .where(
                (e) =>
                    e.key.startsWith('$dir/') &&
                    !e.key.substring(dir.length + 1).contains('/'),
              )
              .toList()
            ..sort((a, b) => a.key.compareTo(b.key));
      targets.addAll(children.map((e) => (e.key, e.value)));
    }

    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>');
    final p = propfindPrefix.isEmpty ? '' : '$propfindPrefix:';
    final nsAttr = propfindPrefix.isEmpty
        ? ' xmlns="DAV:"'
        : ' xmlns:$propfindPrefix="DAV:"';
    xml.write('<${p}multistatus$nsAttr>');
    for (final (nodePath, node) in targets) {
      final segments = nodePath.split('/').where((s) => s.isNotEmpty).toList();
      final href = '/${Uri(pathSegments: segments).path}';
      xml.write('<${p}response><${p}href>');
      xml.write(_escapeXml(node.isDir ? '$href/' : href));
      xml.write('</${p}href><${p}propstat><${p}prop>');
      xml.write(
        node.isDir
            ? '<${p}resourcetype><${p}collection/></${p}resourcetype>'
            : '<${p}resourcetype/><${p}getcontentlength>${node.bytes!.length}</${p}getcontentlength>',
      );
      xml.write(
        '<${p}getlastmodified>${HttpDate.format(node.mtime)}</${p}getlastmodified>',
      );
      if (enableEtag && !node.isDir) {
        xml.write('<${p}getetag>"${node.etag}"</${p}getetag>');
      }
      xml.write(
        '</${p}prop><${p}status>HTTP/1.1 200 OK</${p}status>'
        '</${p}propstat></${p}response>',
      );
    }
    xml.write('</${p}multistatus>');
    await _respond(
      request,
      207,
      body: utf8.encode(xml.toString()),
      contentType: 'application/xml; charset=utf-8',
    );
  }

  Future<void> _get(HttpRequest request, String path) async {
    final node = _store[path];
    final data = node?.bytes;
    if (node == null || node.isDir || data == null) {
      await _respond(request, 404);
      return;
    }
    final commonHeaders = <String, String>{
      'last-modified': HttpDate.format(node.mtime),
      if (enableEtag) 'etag': '"${node.etag}"',
    };

    // If-None-Match → 304（无 ETag 模式不命中：真实弱网盘同样忽略该头）。
    final inm = request.headers.value('if-none-match');
    if (enableEtag && inm != null && _etagMatches(inm, node.etag)) {
      await _respond(request, 304, headers: commonHeaders);
      return;
    }

    final range = enableRange ? request.headers.value('range') : null;
    final parsed = range == null ? null : _parseRange(range, data.length);
    if (range != null && parsed == null) {
      // 不可满足 / 非法 Range → 416。
      await _respond(
        request,
        416,
        headers: {...commonHeaders, 'content-range': 'bytes */${data.length}'},
      );
      return;
    }
    if (parsed != null) {
      final (start, end) = parsed;
      await _respond(
        request,
        206,
        headers: {
          ...commonHeaders,
          'content-range': 'bytes $start-$end/${data.length}',
        },
        body: data.sublist(start, end + 1),
        contentType: 'application/octet-stream',
      );
      return;
    }
    await _respond(
      request,
      200,
      headers: commonHeaders,
      body: data,
      contentType: 'application/octet-stream',
    );
  }

  Future<void> _put(HttpRequest request, String path, List<int> body) async {
    final parent = _parentOf(path);
    if (parent != '/' && _store[parent] == null) {
      await _respond(request, 409);
      return;
    }
    final existing = _store[path];
    if (existing != null && existing.isDir) {
      await _respond(request, 405);
      return;
    }
    final inm = request.headers.value('if-none-match');
    if (inm == '*' && existing != null) {
      await _respond(request, 412);
      return;
    }
    final created = existing == null;
    _store[path] = _Node.file(
      Uint8List.fromList(body),
      etag: sha256.convert(body).toString(),
      mtime: _nextMtime(),
    );
    await _respond(
      request,
      created ? 201 : 204,
      headers: {if (enableEtag) 'etag': '"${_store[path]!.etag}"'},
    );
  }

  Future<void> _mkcol(HttpRequest request, String path) async {
    if (_store.containsKey(path) || path == '/') {
      await _respond(request, 405);
      return;
    }
    final parent = _parentOf(path);
    if (parent != '/' && _store[parent] == null) {
      await _respond(request, 409);
      return;
    }
    _store[path] = _Node.dir(mtime: _nextMtime());
    await _respond(request, 201);
  }

  Future<void> _move(HttpRequest request, String source) async {
    if (!enableMove) {
      await _respond(request, 403);
      return;
    }
    if (!_store.containsKey(source)) {
      await _respond(request, 404);
      return;
    }
    final destRaw = request.headers.value('destination');
    if (destRaw == null) {
      await _respond(request, 400);
      return;
    }
    final dest = normalizePath(
      destRaw.startsWith('http')
          ? (Uri.tryParse(destRaw)?.path ?? '')
          : destRaw,
    );
    if (dest.isEmpty || dest == source) {
      await _respond(request, 403);
      return;
    }
    final destParent = _parentOf(dest);
    if (destParent != '/' && _store[destParent] == null) {
      await _respond(request, 409);
      return;
    }
    final destNode = _store[dest];
    if (destNode != null && (destNode.isDir || _store[source]!.isDir)) {
      // 目标是目录，或目录移到文件上：拒绝。
      await _respond(request, 403);
      return;
    }
    final overwrite =
        (request.headers.value('overwrite') ?? 'F').toUpperCase() == 'T';
    if (destNode != null && !overwrite) {
      await _respond(request, 412);
      return;
    }
    final node = _store.remove(source)!;
    _store[dest] = node;
    await _respond(request, destNode != null ? 204 : 201);
  }

  Future<void> _delete(HttpRequest request, String path) async {
    final node = _store[path];
    if (node == null) {
      await _respond(request, 404);
      return;
    }
    _store.remove(path);
    if (node.isDir) {
      _store.removeWhere((key, _) => key.startsWith('$path/'));
    }
    await _respond(request, 204);
  }

  // ── 工具 ──────────────────────────────────────────────────────────────

  /// 路径归一化：逐段 percent-decode、压缩空段（'/a//b/' → '/a/b'）。
  static String normalizePath(String rawPath) {
    final segments = rawPath.split('/').where((s) => s.isNotEmpty).map((s) {
      try {
        return Uri.decodeComponent(s);
      } on ArgumentError {
        return s;
      }
    }).toList();
    return '/${segments.join('/')}';
  }

  static String _parentOf(String path) {
    final idx = path.lastIndexOf('/');
    return idx <= 0 ? '/' : path.substring(0, idx);
  }

  void _ensureParents(String path) {
    final parent = _parentOf(path);
    if (parent == '/' || _store.containsKey(parent)) return;
    _ensureParents(parent);
    _store[parent] = _Node.dir(mtime: _nextMtime());
  }

  /// 解析 `bytes=a-b | a- | -n`；不可满足（越界）或非法返回 null（416/忽略）。
  static (int, int)? _parseRange(String header, int size) {
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final a = match.group(1)!, b = match.group(2)!;
    if (a.isEmpty && b.isEmpty) return null;
    if (a.isEmpty) {
      final n = int.parse(b);
      if (n == 0 || size == 0) return null;
      final start = size > n ? size - n : 0;
      return (start, size - 1);
    }
    final start = int.parse(a);
    if (start >= size) return null;
    final end = b.isEmpty
        ? size - 1
        : (int.parse(b) < size - 1 ? int.parse(b) : size - 1);
    return (start, end);
  }

  static bool _etagMatches(String ifNoneMatch, String etag) {
    if (ifNoneMatch.trim() == '*') return true;
    for (final part in ifNoneMatch.split(',')) {
      var v = part.trim();
      if (v.startsWith('W/')) v = v.substring(2);
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      if (v == etag) return true;
    }
    return false;
  }

  static String _escapeXml(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  Future<void> _respond(
    HttpRequest request,
    int status, {
    Map<String, String> headers = const {},
    List<int> body = const [],
    String? contentType,
  }) async {
    final noBody = status == 204 || status == 304;
    request.response.statusCode = status;
    headers.forEach(request.response.headers.set);
    if (contentType != null) {
      request.response.headers.contentType = ContentType.parse(contentType);
    }
    if (!noBody && body.isNotEmpty) {
      request.response.contentLength = body.length;
      request.response.add(body);
    }
    await request.response.close();
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

class _Node {
  const _Node.file(this.bytes, {required this.etag, required this.mtime})
    : isDir = false;

  const _Node.dir({required this.mtime})
    : isDir = true,
      bytes = null,
      etag = '';

  final bool isDir;
  final Uint8List? bytes;
  final String etag; // 内容 SHA-256 hex（无引号）
  final DateTime mtime;
}

class _Fault {
  const _Fault({
    required this.method,
    required this.status,
    required this.headers,
  });

  final String method;
  final int status;
  final Map<String, String> headers;
}

/// 便捷断言辅助：从请求日志里数"命中路径前缀的 GET"。
extension MemoryWebDavServerX on MemoryWebDavServer {
  int getMetaGetCount({required String rootPath}) {
    final prefix = 'GET ${Uri(path: rootPath).path}/meta/';
    return countRequests((r) => r.startsWith(prefix) && r.endsWith('.json'));
  }
}
