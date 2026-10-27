/// rclone 本地联调探针（R3-lite，C3）：真实 HTTP 栈上验证 WebDavAdapter
/// 全流程，并把 rclone 的真实响应特征打印成摘要，供
/// `test/backend/webdav_rclone_profile_test.dart` 固化行为断言。
///
/// 用法（探针自管 rclone serve webdav，结束即杀）：
/// ```
/// SYNC_RCLONE_DIR=<rclone.exe 所在目录> dart run tool/rclone_probe.dart
/// ```
///
/// 验证序列（docs/03 §4.3 六动词 + docs/04 §8.1 能力降级）：
/// connect/ensureLayout → PUT/GET meta → If-None-Match 304 → PROPFIND 清单 →
/// tmp→MOVE 上传 → Range 续传 → DELETE → probeCapabilities。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';

Future<void> main() async {
  final summary = await runRcloneProbe();
  // ignore: avoid_print
  stdout.writeln(summary.render());
}

// ── 摘要模型（探针与 profile 测试共用）────────────────────────────────────

/// rclone serve webdav 的真实响应特征摘要。
class RcloneProfileSummary {
  RcloneProfileSummary({
    required this.serverVersion,
    required this.etagHeader,
    required this.etagFormat,
    required this.supports304,
    required this.supportsMove,
    required this.moveStatus,
    required this.supportsRange,
    required this.contentRangeSample,
    required this.propfindPrefixStyle,
    required this.propfindSample,
    required this.retryAfterBehavior,
    required this.capabilities,
    required this.checks,
  });

  /// `rclone version` 首行。
  final String serverVersion;

  /// meta GET 响应的原始 ETag 头（原样含引号/弱标记）。
  final String? etagHeader;

  /// ETag 形态描述（如 `32 位 hex（MD5 形态）`）。
  final String etagFormat;

  /// GET If-None-Match 命中返回 304。
  final bool supports304;

  /// MOVE（Destination/Overwrite）受支持。
  final bool supportsMove;
  final int? moveStatus;

  /// Range 请求返回 206（断点续传可用）。
  final bool supportsRange;

  /// 206 响应的 Content-Range 原文样本。
  final String? contentRangeSample;

  /// PROPFIND XML 前缀风格：`D:` / `d:` / 无前缀（默认命名空间）。
  final String propfindPrefixStyle;

  /// PROPFIND 响应原文样本（截断）。
  final String propfindSample;

  /// Retry-After 能力观察结论。
  final String retryAfterBehavior;

  /// 适配器自探测的能力结论。
  final BackendCapabilities capabilities;

  /// 逐项检查（名称 → 结果描述）。
  final Map<String, String> checks;

  String render() {
    final buf = StringBuffer()
      ..writeln('=== rclone serve webdav 行为摘要 ===')
      ..writeln('server        : $serverVersion')
      ..writeln('etag          : ${etagHeader ?? '（无）'} → $etagFormat')
      ..writeln('304           : $supports304')
      ..writeln('MOVE          : $supportsMove（status=$moveStatus）')
      ..writeln(
        'Range         : $supportsRange（content-range: $contentRangeSample）',
      )
      ..writeln('PROPFIND 前缀 : $propfindPrefixStyle')
      ..writeln('Retry-After   : $retryAfterBehavior')
      ..writeln(
        'adapter probe : move=${capabilities.supportsMove} '
        'etag=${capabilities.supportsEtag} range=${capabilities.supportsRange}',
      );
    for (final e in checks.entries) {
      buf.writeln('  [${e.key}] ${e.value}');
    }
    buf
      ..writeln('--- PROPFIND 原文样本（前 600 字节）---')
      ..writeln(propfindSample);
    return buf.toString();
  }
}

// ── 夹具：探针自管 rclone serve webdav ───────────────────────────────────

/// 解析 rclone 可执行文件路径：`SYNC_RCLONE_DIR` 优先，其次仓库默认落点。
String? resolveRcloneExe() {
  final candidates = <String>[
    if (Platform.environment['SYNC_RCLONE_DIR'] != null)
      Platform.environment['SYNC_RCLONE_DIR']!,
    '../../.tools/rclone/rclone-v1.71.2-windows-amd64',
  ];
  for (final dir in candidates) {
    for (final name in ['rclone.exe', 'rclone']) {
      final f = File('$dir/$name');
      if (f.existsSync()) return f.path;
    }
  }
  return null;
}

class _RcloneServer {
  _RcloneServer(this._process, this.port, this.root);
  final Process _process;
  final int port;
  final Directory root;
  static const username = 'test';
  static const password = 'test123';

  Uri get base => Uri.parse('http://127.0.0.1:$port');

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return 0;
      },
    );
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄释放延迟：尽力清理。
    }
  }
}

Future<_RcloneServer> _startRclone() async {
  final exe = resolveRcloneExe();
  if (exe == null) {
    throw StateError(
      '未找到 rclone：请设置 SYNC_RCLONE_DIR=<rclone.exe 所在目录>，'
      '或将 rclone 解压到仓库 .tools/rclone/ 下。',
    );
  }
  final root = await Directory.systemTemp.createTemp('syncr_rclone_root');

  // 随机空闲端口。
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();

  final process = await Process.start(exe, [
    'serve',
    'webdav',
    root.path,
    '--addr',
    '127.0.0.1:$port',
    '--user',
    _RcloneServer.username,
    '--pass',
    _RcloneServer.password,
  ]);
  // 吞掉 stdout/stderr 防管道背压（诊断可按需打开）。
  process.stdout.drain<void>().ignore();
  process.stderr.drain<void>().ignore();

  // 等服务器就绪：能拿到任意 HTTP 响应（无鉴权 GET 通常 401）。
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (true) {
    if (DateTime.now().isAfter(deadline)) {
      process.kill();
      throw StateError('rclone serve webdav 20s 内未就绪');
    }
    try {
      final client = HttpClient();
      final req = await client
          .openUrl('GET', Uri.parse('http://127.0.0.1:$port/'))
          .timeout(const Duration(seconds: 2));
      final resp = await req.close();
      await resp.drain<void>();
      client.close();
      break; // 有 HTTP 响应即就绪
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }
  return _RcloneServer(process, port, root);
}

// ── 探针主体 ─────────────────────────────────────────────────────────────

/// 完整跑一遍探针（自管 rclone 启停）。profile 测试直接复用。
Future<RcloneProfileSummary> runRcloneProbe() async {
  final server = await _startRclone();
  final checks = <String, String>{};
  WebDavAdapter? adapter;
  try {
    adapter = WebDavAdapter();
    final config = BackendConfig(
      kind: BackendKind.webdav,
      baseUrl: server.base.toString(),
      username: _RcloneServer.username,
      password: _RcloneServer.password,
      rootPath: '/Apps/SyncReader',
    );

    // 1. connect + ensureLayout。
    await adapter.connect(config);
    checks['connect'] = 'OK（PROPFIND Depth:0 同步根）';
    await adapter.ensureLayout();
    checks['ensureLayout'] = 'OK（meta/books/tmp/library.json）';

    // 2. PUT/GET meta（走适配器：写前重读 + Basic 头）。
    final meta = _sampleMeta();
    await adapter.putMeta(meta, expectedRev: 0);
    final back = await adapter.getMeta(meta.bookId);
    checks['PUT/GET meta'] = back != null && back.rev == 1
        ? 'OK（rev=1 往返一致）'
        : 'FAIL（rev=${back?.rev}）';

    // 3. If-None-Match 304（原始 GET 特征化）。
    final metaPath = '/Apps/SyncReader/meta/${meta.bookId}.json';
    final etag = await _rawGetEtag(server.base, metaPath);
    final supports304 = await _rawCheck304(server.base, metaPath, etag);
    checks['If-None-Match 304'] = supports304 ? 'OK（304 空体）' : '不支持（恒 200）';

    // 4. PROPFIND 清单（适配器语义 + 原文样本）。
    final listing = await adapter.listMetas();
    final xml = await _rawPropfind(
      server.base,
      '/Apps/SyncReader/meta',
      depth: 1,
    );
    final prefixStyle = _detectPropfindPrefix(xml);
    checks['PROPFIND 清单'] =
        'OK（stubs=${listing.stubs.length}，前缀风格=$prefixStyle）';

    // 5. 正文上传（适配器按能力自动走 tmp 暂存 → MOVE 提交）+ 往返校验。
    final content = utf8.encode('rclone probe content — ' * 20);
    final tmpDir = await Directory.systemTemp.createTemp('syncr_probe');
    final bookFile = File('${tmpDir.path}/probe.txt')
      ..writeAsBytesSync(content);
    try {
      final hash = 'sha256:${sha256.convert(content).toString()}';
      await adapter.uploadBook(meta.bookId, bookFile, hash);
      final roundTrip = <int>[];
      await for (final chunk in adapter.downloadBook(meta.bookId)) {
        roundTrip.addAll(chunk);
      }
      final uploadOk =
          sha256.convert(roundTrip).toString() ==
          sha256.convert(content).toString();
      checks['tmp→MOVE 上传'] = uploadOk ? 'OK（上传-下载哈希一致）' : 'FAIL';
    } finally {
      await tmpDir.delete(recursive: true).catchError((Object _) => tmpDir);
    }

    // MOVE 原始状态码（单独喂一个探测文件，特征化用）。
    final moveStatus = await _rawMoveProbe(server.base);
    final supportsMove =
        moveStatus != null && moveStatus >= 200 && moveStatus < 300;
    checks['MOVE（原始）'] = 'status=$moveStatus';

    // 6. Range 续传（原始特征化 + 适配器 startByte 切片）。
    final bookPath = '/Apps/SyncReader/books/${meta.bookId}.txt';
    final range = await _rawRangeProbe(server.base, bookPath);
    checks['Range（原始）'] = range.$1
        ? 'OK（206，content-range: ${range.$2}）'
        : '不支持';
    final tail = <int>[];
    await for (final chunk in adapter.downloadBook(
      meta.bookId,
      startByte: 16,
    )) {
      tail.addAll(chunk);
    }
    final expectedTail = content.length > 16 ? content.sublist(16) : <int>[];
    checks['Range 续传（适配器）'] = _bytesEqual(tail, expectedTail)
        ? 'OK（bytes=16- 切片一致）'
        : 'FAIL';

    // 7. DELETE（幂等 404 容忍）。
    await adapter.deleteMeta(meta.bookId);
    final afterDelete = await adapter.getMeta(meta.bookId);
    checks['DELETE'] = afterDelete == null ? 'OK（删除后 404 → null）' : 'FAIL';

    // 8. probeCapabilities（适配器自探测结论）。
    final capabilities = await adapter.probeCapabilities();
    checks['probeCapabilities'] =
        'move=${capabilities.supportsMove} etag=${capabilities.supportsEtag} '
        'range=${capabilities.supportsRange}';

    return RcloneProfileSummary(
      serverVersion: await _rcloneVersion(),
      etagHeader: etag,
      etagFormat: etag == null ? '未返回 ETag' : _describeEtag(etag),
      supports304: supports304,
      supportsMove: supportsMove,
      moveStatus: moveStatus,
      supportsRange: range.$1,
      contentRangeSample: range.$2,
      propfindPrefixStyle: prefixStyle,
      propfindSample: xml.length <= 600 ? xml : '${xml.substring(0, 600)}…',
      retryAfterBehavior:
          '本地 rclone 不限流：观察不到 429/503 + Retry-After'
          '（适配器的 Retry-After 解析已由内存服务器 429/503 用例覆盖）',
      capabilities: capabilities,
      checks: checks,
    );
  } finally {
    await adapter?.dispose();
    await server.stop();
  }
}

// ── 原始 HTTP 特征化（绕过适配器，直接观察响应特征）─────────────────────────

Future<(HttpClientResponse, List<int>)> _raw(
  Uri base,
  String method,
  String path, {
  Map<String, String>? headers,
  List<int>? body,
}) async {
  final client = HttpClient();
  try {
    final auth = base64Encode(
      utf8.encode('${_RcloneServer.username}:${_RcloneServer.password}'),
    );
    final req = await client.openUrl(method, base.resolve(path));
    req.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
    headers?.forEach(req.headers.set);
    if (body != null) {
      req.add(body);
    }
    final resp = await req.close();
    final bytes = await resp.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    return (resp, bytes);
  } finally {
    client.close();
  }
}

Future<String?> _rawGetEtag(Uri base, String path) async {
  final (resp, _) = await _raw(base, 'GET', path);
  return resp.headers.value('etag');
}

Future<bool> _rawCheck304(Uri base, String path, String? etag) async {
  if (etag == null) return false;
  final (resp, _) = await _raw(
    base,
    'GET',
    path,
    headers: {'if-none-match': etag},
  );
  return resp.statusCode == 304;
}

Future<String> _rawPropfind(Uri base, String path, {required int depth}) async {
  final (_, bytes) = await _raw(
    base,
    'PROPFIND',
    path,
    headers: {
      'depth': '$depth',
      'content-type': 'application/xml; charset=utf-8',
    },
    body: utf8.encode(_propfindBody),
  );
  return utf8.decode(bytes);
}

Future<int?> _rawMoveProbe(Uri base) async {
  final src = '/Apps/SyncReader/tmp/probe-move-src.txt';
  await _raw(base, 'PUT', src, body: utf8.encode('move-me'));
  final dest = base
      .resolve('/Apps/SyncReader/tmp/probe-move-dst.txt')
      .toString();
  final (resp, _) = await _raw(
    base,
    'MOVE',
    src,
    headers: {'destination': dest, 'overwrite': 'T'},
  );
  return resp.statusCode;
}

Future<(bool, String?)> _rawRangeProbe(Uri base, String path) async {
  final (resp, _) = await _raw(
    base,
    'GET',
    path,
    headers: {'range': 'bytes=0-0'},
  );
  return (resp.statusCode == 206, resp.headers.value('content-range'));
}

String _detectPropfindPrefix(String xml) {
  if (RegExp(r'<D:multistatus').hasMatch(xml)) return 'D:（大写）';
  if (RegExp(r'<d:multistatus').hasMatch(xml)) return 'd:（小写）';
  if (RegExp(r'<multistatus[ >]').hasMatch(xml)) return '无前缀（默认命名空间）';
  return '未知';
}

String _describeEtag(String etag) {
  final v = etag.trim();
  final weak = v.startsWith('W/');
  final inner = v.replaceAll('W/', '').replaceAll('"', '');
  final kind = RegExp(r'^[0-9a-f]{32}$').hasMatch(inner)
      ? '32 位 hex（MD5 形态）'
      : RegExp(r'^[0-9a-f]{40}$').hasMatch(inner)
      ? '40 位 hex（SHA-1 形态）'
      : RegExp(r'^[0-9a-f]{64}$').hasMatch(inner)
      ? '64 位 hex（SHA-256 形态）'
      : '其他（$inner）';
  return '${weak ? '弱 ' : ''}$kind';
}

Future<String> _rcloneVersion() async {
  final exe = resolveRcloneExe();
  if (exe == null) return 'unknown';
  final result = await Process.run(exe, ['version']);
  return (result.stdout as String).split('\n').first.trim();
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

const String _propfindBody =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<D:propfind xmlns:D="DAV:"><D:prop>'
    '<D:getetag/><D:getcontentlength/><D:getlastmodified/><D:resourcetype/>'
    '</D:prop></D:propfind>';

BookMeta _sampleMeta() {
  final now = DateTime.now().toUtc();
  return BookMeta(
    schemaVersion: kCurrentSchemaVersion,
    bookId:
        '01PROBE${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase().padLeft(12, '0')}',
    rev: 1,
    deviceId: '01PROBEDEVICE0000000',
    deviceName: 'rclone-probe',
    createdAt: now,
    updatedAt: now,
    book: BookInfo(
      title: 'rclone 探针书',
      author: '',
      format: 'txt',
      fileName: 'probe.txt',
      contentHash: 'sha256:$_sampleHash',
      sizeBytes: 16,
      tocFingerprint: 'tfp:probe',
    ),
    reading: ReadingStats(totalSeconds: 0, lastReadAt: now),
  );
}

/// 探针样本哈希（常量，避免每次变化）。
const String _sampleHash =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
