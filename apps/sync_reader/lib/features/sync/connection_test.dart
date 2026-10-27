/// WebDAV 连接测试与诊断（FR-505，FR-501 向导第 3 步）。
///
/// 依次执行：列根目录（PROPFIND）→ MKCOL 探针目录 → PUT/GET/DELETE 探针文件
/// → MOVE 探针 → 清理，逐项记录往返延迟；汇总 [BackendCapabilities]
/// （MOVE/ETag/Range 支持情况）。失败按 DNS/超时/401/403/5xx 分类文案。
///
/// 硬约束：不落任何凭据日志（错误文案与步骤明细均不含账号/密码）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sync_core/sync_core.dart';

/// 单个测试步骤结果。
class ConnectionTestStep {
  const ConnectionTestStep({
    required this.name,
    required this.ok,
    this.latencyMs,
    this.detail,
  });

  /// 步骤名：列目录 / 建目录 / 写探针 / 读探针 / 删探针 / MOVE。
  final String name;
  final bool ok;

  /// 往返延迟（毫秒）。
  final int? latencyMs;

  /// 补充说明（不含凭据）。
  final String? detail;
}

/// 连接测试汇总结果。
class ConnectionTestResult {
  const ConnectionTestResult({
    required this.steps,
    required this.success,
    this.failureText,
    this.capabilities,
  });

  final List<ConnectionTestStep> steps;
  final bool success;

  /// 失败分类文案（成功为 null）。
  final String? failureText;

  /// 探测到的能力（MOVE/ETag/Range）。
  final BackendCapabilities? capabilities;
}

/// 连接测试服务。
///
/// 直接走 dart:io HTTP（B2 不依赖 B1 的 WebDAV 适配器实现；Phase C 可将其
/// 替换/复用为适配器的 connect + probeCapabilities）。
final class ConnectionTester {
  ConnectionTester({
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = timeout;
  }

  final HttpClient _client;

  /// 单请求超时。
  final Duration timeout;

  /// 坚果云默认服务地址（docs/05 §1）。
  static const defaultBaseUrl = 'https://dav.jianguoyun.com/dav/';

  /// 默认同步根目录。
  static const defaultRootPath = '/Apps/SyncReader';

  /// 执行全套测试。任何凭据相关参数仅用于构造请求头，绝不进入结果文案。
  Future<ConnectionTestResult> test({
    required String baseUrl,
    required String username,
    required String password,
    String rootPath = defaultRootPath,
  }) async {
    final steps = <ConnectionTestStep>[];
    final probeName = 'syncr-probe-${DateTime.now().millisecondsSinceEpoch}';
    final probeDir = joinPath(rootPath, probeName);
    var moveSupported = false;
    var etagSeen = false;
    var rangeSupported = false;

    Future<int> request(
      String method,
      Uri uri, {
      Map<String, String> headers = const {},
      String? body,
    }) async {
      final req = await _client.openUrl(method, uri);
      _setAuth(req, username, password);
      headers.forEach(req.headers.set);
      final content = body == null ? null : utf8.encode(body);
      if (content != null) {
        req.headers.contentLength = content.length;
        req.add(content);
      }
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode;
    }

    try {
      // 1. 列根目录（PROPFIND Depth:1；404 视为"目录不存在，将由 ensureLayout 创建"）。
      final rootUri = _uri(baseUrl, rootPath);
      final listStatus = await _timed(steps, '列目录', () async {
        final req = await _client.openUrl('PROPFIND', rootUri);
        _setAuth(req, username, password);
        req.headers.set('Depth', '1');
        req.headers.contentLength = 0;
        final res = await req.close().timeout(timeout);
        final status = res.statusCode;
        await res.drain<void>();
        return status;
      });
      if (!_okOrNotFound(listStatus, steps, '列目录')) {
        return _failure(steps, _classifyStatus(listStatus));
      }

      // 2. MKCOL 探针目录。
      final mkcolStatus = await _timed(steps, '建探针目录', () {
        return request('MKCOL', _uri(baseUrl, probeDir));
      });
      if (!_expect(
        mkcolStatus,
        const {201, 405},
        steps,
        '建探针目录',
        detail405: '目录已存在',
      )) {
        return _failure(steps, _classifyStatus(mkcolStatus));
      }

      // 3. PUT 探针文件。
      final probeFile = joinPath(probeDir, 'probe.txt');
      final putStatus = await _timed(steps, '写探针文件', () {
        return request('PUT', _uri(baseUrl, probeFile), body: 'sync-reader');
      });
      if (!_expect(putStatus, const {200, 201, 204}, steps, '写探针文件')) {
        return _failure(steps, _classifyStatus(putStatus));
      }

      // 4. GET 读回（记录 ETag → 能力探测）。
      String? etag;
      final getStatus = await _timed(steps, '读探针文件', () async {
        final req = await _client.openUrl('GET', _uri(baseUrl, probeFile));
        _setAuth(req, username, password);
        final res = await req.close().timeout(timeout);
        await res.drain<void>();
        etag = res.headers.value('etag');
        return res.statusCode;
      });
      if (!_expect(getStatus, const {200}, steps, '读探针文件')) {
        return _failure(steps, _classifyStatus(getStatus));
      }
      etagSeen = etag != null;

      // 5. Range 探测（请求前 4 字节，206 = 支持；部分服务忽略 Range 回 200）。
      final rangeStatus = await _timed(steps, 'Range 探测', () async {
        final req = await _client.openUrl('GET', _uri(baseUrl, probeFile));
        _setAuth(req, username, password);
        req.headers.set('Range', 'bytes=0-3');
        final res = await req.close().timeout(timeout);
        final status = res.statusCode;
        await res.drain<void>();
        return status;
      });
      rangeSupported = rangeStatus == 206;

      // 6. DELETE 探针文件 + MOVE 探针（先 PUT 一个待移动文件）。
      final deleteStatus = await _timed(steps, '删探针文件', () {
        return request('DELETE', _uri(baseUrl, probeFile));
      });
      if (!_expect(deleteStatus, const {200, 202, 204, 404}, steps, '删探针文件')) {
        return _failure(steps, _classifyStatus(deleteStatus));
      }

      final moveSource = joinPath(probeDir, 'move-src.txt');
      final moveTarget = joinPath(probeDir, 'move-dst.txt');
      await request('PUT', _uri(baseUrl, moveSource), body: 'move-me');
      final moveStatus = await _timed(steps, 'MOVE 探测', () async {
        final req = await _client.openUrl('MOVE', _uri(baseUrl, moveSource));
        _setAuth(req, username, password);
        req.headers.set('Destination', _uri(baseUrl, moveTarget).toString());
        req.headers.contentLength = 0;
        final res = await req.close().timeout(timeout);
        final status = res.statusCode;
        await res.drain<void>();
        return status;
      });
      moveSupported = const {200, 201, 204}.contains(moveStatus);
      if (!_expect(
        moveStatus,
        const {200, 201, 204, 403, 405, 501},
        steps,
        'MOVE 探测',
        detail403: '服务端禁止 MOVE（将回退非原子提交）',
      )) {
        return _failure(steps, _classifyStatus(moveStatus));
      }

      // 7. 清理探针目录（尽力而为，失败不影响结果）。
      try {
        await request('DELETE', _uri(baseUrl, probeDir));
      } on Exception {
        // 清理失败静默：下次探针使用新时间戳目录名。
      }

      return ConnectionTestResult(
        steps: steps,
        success: true,
        capabilities: BackendCapabilities(
          supportsMove: moveSupported,
          supportsEtag: etagSeen,
          supportsRange: rangeSupported,
        ),
      );
    } on SocketException catch (e) {
      return _failure(
        steps,
        '无法连接服务器（DNS 解析失败或网络不可达）：${e.osError?.errorCode ?? ''}',
      );
    } on HandshakeException {
      return _failure(steps, 'TLS 握手失败，请检查服务器证书');
    } on TimeoutException {
      return _failure(steps, '连接超时，请检查地址与网络');
    } on HttpException catch (e) {
      return _failure(steps, '请求异常：${e.message}');
    }
  }

  void _setAuth(HttpClientRequest req, String username, String password) {
    final token = base64Encode(utf8.encode('$username:$password'));
    req.headers.set('Authorization', 'Basic $token');
  }

  /// 带延迟记录的步骤执行：返回动作结果；同时写入步骤行。
  Future<int> _timed(
    List<ConnectionTestStep> steps,
    String name,
    Future<int> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    var ok = true;
    int status;
    try {
      status = await action();
    } on Object {
      ok = false;
      status = 0;
      rethrow;
    } finally {
      watch.stop();
      steps.add(
        ConnectionTestStep(
          name: name,
          ok: ok,
          latencyMs: watch.elapsedMilliseconds,
        ),
      );
    }
    return status;
  }

  bool _expect(
    int? status,
    Set<int> okCodes,
    List<ConnectionTestStep> steps,
    String name, {
    String? detail405,
    String? detail403,
  }) {
    if (status != null && okCodes.contains(status)) {
      if (status == 405 && detail405 != null) {
        steps.add(ConnectionTestStep(name: name, ok: true, detail: detail405));
      }
      if (status == 403 && detail403 != null) {
        steps.add(ConnectionTestStep(name: name, ok: true, detail: detail403));
      }
      return true;
    }
    steps.add(
      ConnectionTestStep(
        name: name,
        ok: false,
        detail: 'HTTP ${status ?? '?'}',
      ),
    );
    return false;
  }

  /// PROPFIND 允许 207/200；404 = 根目录尚不存在（视为可继续）。
  bool _okOrNotFound(int status, List<ConnectionTestStep> steps, String name) {
    if (status == 404) {
      steps.add(
        ConnectionTestStep(name: name, ok: true, detail: '目录不存在（首次连接时将自动创建）'),
      );
      return true;
    }
    return _expect(status, const {200, 207}, steps, name);
  }

  ConnectionTestResult _failure(List<ConnectionTestStep> steps, String text) =>
      ConnectionTestResult(steps: steps, success: false, failureText: text);

  /// 状态码 → 分类文案（FR-505：DNS/超时/401/403/5xx）。
  static String classifyStatus(int? status) {
    if (status == 401) return '密码错误或账号无效（HTTP 401）';
    if (status == 403) return '权限不足，请检查应用密码与应用授权（HTTP 403）';
    if (status != null && status >= 500 && status < 600) {
      return '服务异常（HTTP $status），请稍后重试';
    }
    if (status == null) return '网络不可达';
    return '请求被拒绝（HTTP $status）';
  }

  String _classifyStatus(int? status) => classifyStatus(status);

  /// 拼接 WebDAV 路径（`/a/b` + `c` → `/a/b/c`，容忍多余斜杠）。
  static String joinPath(String base, String segment) {
    final left = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final right = segment.startsWith('/') ? segment.substring(1) : segment;
    return '$left/$right';
  }

  Uri _uri(String baseUrl, String path) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalized');
  }
}
