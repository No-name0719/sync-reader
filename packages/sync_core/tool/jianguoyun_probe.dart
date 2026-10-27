/// 坚果云 WebDAV 真实环境探针（R3 联调专项）。
///
/// 凭据从仓库根 `.secrets/jianguoyun.txt` 读取（三行：baseUrl / 账号 /
/// 应用密码；目录已 git-ignore，绝不入库），或用环境变量覆盖：
/// `SYNC_WEBDAV_BASE_URL` / `SYNC_WEBDAV_ACCOUNT` / `SYNC_WEBDAV_PASSWORD`。
///
/// 用法：
/// ```
/// dart run tool/jianguoyun_probe.dart
/// ```
///
/// 观测序列（对齐 B1 遗留的 R3 验证项）：
/// connect/ensureLayout（MKCOL 既有目录的返回码）→ PUT/GET meta →
/// **PUT 响应是否携带 ETag**（决定两级清单热缓存是否零补拉）→
/// If-None-Match 304 → PROPFIND 清单（前缀风格）→ tmp→MOVE 上传 →
/// Range 续传 → **gzip**（Accept-Encoding 是否生效）→ DELETE →
/// probeCapabilities。探针产物（meta/正文/tmp 探测文件）全部清理。
///
/// 安全：任何输出不得含应用密码；账号打码显示。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sync_core/sync_core.dart';

/// 坚果云（或任意 WebDAV）联调凭据。
class WebDavCredentials {
  WebDavCredentials(this.baseUrl, this.account, this.password);

  final String baseUrl;
  final String account;
  final String password;

  /// 读取顺序：环境变量 → 仓库根 `.secrets/jianguoyun.txt`（三行）。
  static WebDavCredentials? load() {
    final env = Platform.environment;
    final url = env['SYNC_WEBDAV_BASE_URL'];
    final account = env['SYNC_WEBDAV_ACCOUNT'];
    final password = env['SYNC_WEBDAV_PASSWORD'];
    if (url != null && account != null && password != null) {
      return WebDavCredentials(url, account, password);
    }
    final f = File('../../.secrets/jianguoyun.txt');
    if (!f.existsSync()) return null;
    final lines = f
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 3) return null;
    return WebDavCredentials(lines[0], lines[1], lines[2]);
  }

  /// 打码账号（前 3 字符 + ***）。
  String get maskedAccount =>
      account.length <= 3 ? '***' : '${account.substring(0, 3)}***';
}

Future<void> main() async {
  final credentials = WebDavCredentials.load();
  if (credentials == null) {
    // ignore: avoid_print
    stdout.writeln(
      '未找到凭据：请将 baseUrl/账号/应用密码 三行写入 '
      '`.secrets/jianguoyun.txt`，或设置 SYNC_WEBDAV_* 环境变量。',
    );
    exitCode = 2;
    return;
  }
  final summary = await runJianguoyunProbe(credentials);
  // ignore: avoid_print
  stdout.writeln(summary.render());
}

// ── 摘要模型（探针与 profile 测试共用）────────────────────────────────────

/// 坚果云真实响应特征摘要。
class JianguoyunProfileSummary {
  JianguoyunProfileSummary({
    required this.accountMasked,
    required this.etagHeader,
    required this.etagFormat,
    required this.putEtagHeader,
    required this.putEtagMatchesGet,
    required this.supports304,
    required this.mkcolExistingStatus,
    required this.supportsMove,
    required this.moveStatus,
    required this.supportsRange,
    required this.contentRangeSample,
    required this.propfindPrefixStyle,
    required this.propfindSample,
    required this.gzipSupported,
    required this.capabilities,
    required this.checks,
  });

  final String accountMasked;

  /// meta GET 响应的原始 ETag 头。
  final String? etagHeader;
  final String etagFormat;

  /// PUT 响应的 ETag 头（null = 不回带；决定 etag→rev 缓存是否零补拉）。
  final String? putEtagHeader;

  /// PUT 回带的 ETag 与随后 GET 的是否一致（缓存回填正确性前提）。
  final bool putEtagMatchesGet;

  final bool supports304;

  /// MKCOL 一个已存在目录的返回码（ensureLayout 幂等判定的依据）。
  final int? mkcolExistingStatus;

  final bool supportsMove;
  final int? moveStatus;

  final bool supportsRange;
  final String? contentRangeSample;

  final String propfindPrefixStyle;
  final String propfindSample;

  /// GET（可压缩内容）带 Accept-Encoding: gzip 时是否回 gzip。
  final bool gzipSupported;

  final BackendCapabilities capabilities;
  final Map<String, String> checks;

  String render() {
    final buf = StringBuffer()
      ..writeln('=== 坚果云 WebDAV 行为摘要（账号 $accountMasked）===')
      ..writeln('etag          : ${etagHeader ?? '（无）'} → $etagFormat')
      ..writeln(
        'PUT-ETag      : ${putEtagHeader ?? '（不回带）'}'
        '（与 GET 一致: $putEtagMatchesGet）',
      )
      ..writeln('304           : $supports304')
      ..writeln('MKCOL 既有    : status=$mkcolExistingStatus')
      ..writeln('MOVE          : $supportsMove（status=$moveStatus）')
      ..writeln(
        'Range         : $supportsRange（content-range: $contentRangeSample）',
      )
      ..writeln('gzip          : $gzipSupported')
      ..writeln('PROPFIND 前缀 : $propfindPrefixStyle')
      ..writeln(
        'adapter probe : move=${capabilities.supportsMove} '
        'etag=${capabilities.supportsEtag} range=${capabilities.supportsRange}',
      );
    for (final e in checks.entries) {
      buf.writeln('  [${e.key}] ${e.value}');
    }
    buf
      ..writeln('--- PROPFIND 原文样本（前 800 字节）---')
      ..writeln(propfindSample);
    return buf.toString();
  }
}

// ── 探针主体 ─────────────────────────────────────────────────────────────

const String _root = '/Apps/SyncReader';

/// 完整跑一遍探针（真实坚果云；产物清理）。profile 测试直接复用。
Future<JianguoyunProfileSummary> runJianguoyunProbe(
  WebDavCredentials credentials,
) async {
  final checks = <String, String>{};
  final base = Uri.parse(credentials.baseUrl);
  final adapter = WebDavAdapter();
  try {
    final config = BackendConfig(
      kind: BackendKind.webdav,
      baseUrl: credentials.baseUrl,
      username: credentials.account,
      password: credentials.password,
      rootPath: _root,
    );

    // 0. 清理上一轮探针遗留（books/01JGYPROBE*、meta/pyprobe.json）。
    await _cleanupLeftovers(base, credentials);

    // 1. connect + ensureLayout。
    await adapter.connect(config);
    checks['connect'] = 'OK（PROPFIND Depth:0 同步根）';
    await adapter.ensureLayout();
    checks['ensureLayout'] = 'OK（meta/books/tmp/library.json）';

    // 2. MKCOL 既有目录返回码（幂等判定依据）。
    final mkcolExisting = await _raw(base, credentials, 'MKCOL', '$_root/meta');
    final mkcolStatus = mkcolExisting.$1.statusCode;
    checks['MKCOL 既有目录'] = 'status=$mkcolStatus';

    // 3. PUT/GET meta（适配器语义：写前重读）+ PUT 响应 ETag 观测。
    final meta = _sampleMeta();
    final putResp = await _raw(
      base,
      credentials,
      'PUT',
      '$_root/meta/${meta.bookId}.json',
      body: utf8.encode(meta.toJsonString()),
    );
    final putEtag = putResp.$1.headers.value('etag');
    checks['PUT meta'] =
        'status=${putResp.$1.statusCode}${putEtag == null ? '（无 ETag）' : '（ETag 回带）'}';
    final back = await adapter.getMeta(meta.bookId);
    checks['GET meta'] = back != null && back.rev == 1
        ? 'OK（rev=1 往返一致）'
        : 'FAIL（rev=${back?.rev}）';
    final getEtag = await _rawGetEtag(
      base,
      credentials,
      '$_root/meta/${meta.bookId}.json',
    );
    final putEtagMatchesGet =
        putEtag != null && getEtag != null && putEtag.trim() == getEtag.trim();

    // 4. If-None-Match 304。
    final supports304 = await _rawCheck304(
      base,
      credentials,
      '$_root/meta/${meta.bookId}.json',
      getEtag,
    );
    checks['If-None-Match 304'] = supports304 ? 'OK（304）' : '不支持（恒 200）';

    // 5. PROPFIND 清单 + 前缀风格。
    final listing = await adapter.listMetas();
    final xml = await _rawPropfind(base, credentials, '$_root/meta', depth: 1);
    final prefixStyle = _detectPropfindPrefix(xml);
    checks['PROPFIND 清单'] =
        'OK（stubs=${listing.stubs.length}，前缀风格=$prefixStyle）';

    // 6. tmp→MOVE 上传 + 往返校验。
    final content = utf8.encode('jianguoyun probe content — ' * 20);
    final tmpDir = await Directory.systemTemp.createTemp('syncr_jgy_probe');
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
      checks['tmp→MOVE 上传'] = uploadOk ? 'OK（哈希一致）' : 'FAIL';
    } finally {
      await tmpDir.delete(recursive: true).catchError((Object _) => tmpDir);
    }

    // MOVE 原始状态码。
    final moveStatus = await _rawMoveProbe(base, credentials);
    final supportsMove =
        moveStatus != null && moveStatus >= 200 && moveStatus < 300;
    checks['MOVE（原始）'] = 'status=$moveStatus';

    // 7. Range 续传。
    final bookPath = '$_root/books/${meta.bookId}.txt';
    final range = await _rawRangeProbe(base, credentials, bookPath);
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

    // 8. gzip（坚果云对元数据体积的影响）。
    final gzip = await _rawGzipProbe(base, credentials, bookPath);
    checks['gzip'] = gzip
        ? 'OK（Accept-Encoding: gzip → Content-Encoding: gzip）'
        : '未启用（恒明文）';

    // 9. DELETE（幂等 404 容忍）+ 产物清理。
    await adapter.deleteMeta(meta.bookId);
    final afterDelete = await adapter.getMeta(meta.bookId);
    checks['DELETE'] = afterDelete == null ? 'OK（删除后 404 → null）' : 'FAIL';
    await _cleanupProbeArtifacts(base, credentials, meta.bookId);

    // 10. probeCapabilities。
    final capabilities = await adapter.probeCapabilities();
    checks['probeCapabilities'] =
        'move=${capabilities.supportsMove} etag=${capabilities.supportsEtag} '
        'range=${capabilities.supportsRange}';

    return JianguoyunProfileSummary(
      accountMasked: credentials.maskedAccount,
      etagHeader: getEtag,
      etagFormat: getEtag == null ? '未返回 ETag' : _describeEtag(getEtag),
      putEtagHeader: putEtag,
      putEtagMatchesGet: putEtagMatchesGet,
      supports304: supports304,
      mkcolExistingStatus: mkcolStatus,
      supportsMove: supportsMove,
      moveStatus: moveStatus,
      supportsRange: range.$1,
      contentRangeSample: range.$2,
      propfindPrefixStyle: prefixStyle,
      propfindSample: xml.length <= 800 ? xml : '${xml.substring(0, 800)}…',
      gzipSupported: gzip,
      capabilities: capabilities,
      checks: checks,
    );
  } finally {
    await adapter.dispose();
  }
}

/// 清理历史探针遗留产物（幂等，逐个 DELETE，404 容忍）。
Future<void> _cleanupLeftovers(Uri base, WebDavCredentials credentials) async {
  for (final dir in ['books', 'meta', 'tmp']) {
    try {
      final (_, bytes) = await _raw(
        base,
        credentials,
        'PROPFIND',
        '$_root/$dir',
        headers: {
          'depth': '1',
          'content-type': 'application/xml; charset=utf-8',
        },
        body: utf8.encode(_propfindBody),
      );
      // parseMultistatus 未导出：探针清理只需 href 文件名，正则足够。
      final hrefs = RegExp(
        r'<(?:[Dd]:)?href>([^<]+)</(?:[Dd]:)?href>',
      ).allMatches(utf8.decode(bytes)).map((m) => m.group(1)!);
      for (final href in hrefs) {
        final name = Uri.decodeComponent(
          href.split('/').where((s) => s.isNotEmpty).last,
        );
        final isLeftover =
            name.startsWith('01JGYPROBE') ||
            name.contains('probe') ||
            name.contains('pyprobe');
        if (!isLeftover) continue;
        await _raw(base, credentials, 'DELETE', '$_root/$dir/$name');
        // ignore: avoid_print
        stdout.writeln('cleanup: $dir/$name 已删除');
      }
    } on Exception catch (e) {
      // ignore: avoid_print
      stdout.writeln('cleanup $dir/ 跳过：$e');
    }
  }
}

// ── 原始 HTTP 特征化 ─────────────────────────────────────────────────────

/// 共享 keep-alive HTTP 客户端（坚果云 nginx 对高频新建连接有反滥用
/// 节流——R3 实测短间隔逐请求新建连接会收到 410 Gone；适配器/dio 因
/// 连接复用不受影响。探针必须模拟同样的连接模式）。
HttpClient? _sharedClient;
HttpClient get _client => _sharedClient ??= HttpClient();

/// 裸请求节奏间隔（毫秒）——降低突发强度。
const int _paceMillis = 350;

Future<void> _pace() async {
  await Future<void>.delayed(const Duration(milliseconds: _paceMillis));
}

/// 拼接 baseUrl（含其路径前缀，如 /dav/）与资源路径。
/// 注意不能用 `base.resolve('/Apps/...')`——绝对路径引用会丢弃 base 的
/// `/dav/` 前缀（R3 实测：这正是裸探针拿到 nginx 410 的原因）。
Uri _u(Uri base, String path) {
  final basePath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(path: '$basePath$path');
}

Future<(HttpClientResponse, List<int>)> _rawOnce(
  Uri base,
  WebDavCredentials credentials,
  String method,
  String path, {
  Map<String, String>? headers,
  List<int>? body,
}) async {
  final auth = base64Encode(
    utf8.encode('${credentials.account}:${credentials.password}'),
  );
  final req = await _client.openUrl(method, _u(base, path));
  req.headers.set(HttpHeaders.authorizationHeader, 'Basic $auth');
  headers?.forEach(req.headers.set);
  if (body != null) {
    req.headers.contentLength = body.length;
    req.add(body);
  }
  final resp = await req.close();
  final bytes = await resp.fold<List<int>>(
    <int>[],
    (acc, chunk) => acc..addAll(chunk),
  );
  return (resp, bytes);
}

/// 带节奏与 410 退避的裸请求（410 = 触发节流，等待后重试一次）。
Future<(HttpClientResponse, List<int>)> _raw(
  Uri base,
  WebDavCredentials credentials,
  String method,
  String path, {
  Map<String, String>? headers,
  List<int>? body,
}) async {
  await _pace();
  var (resp, bytes) = await _rawOnce(
    base,
    credentials,
    method,
    path,
    headers: headers,
    body: body,
  );
  if (resp.statusCode == 410) {
    await Future<void>.delayed(const Duration(seconds: 3));
    (resp, bytes) = await _rawOnce(
      base,
      credentials,
      method,
      path,
      headers: headers,
      body: body,
    );
  }
  return (resp, bytes);
}

Future<String?> _rawGetEtag(
  Uri base,
  WebDavCredentials credentials,
  String path,
) async {
  final (resp, _) = await _raw(base, credentials, 'GET', path);
  return resp.headers.value('etag');
}

Future<bool> _rawCheck304(
  Uri base,
  WebDavCredentials credentials,
  String path,
  String? etag,
) async {
  if (etag == null) return false;
  final (resp, _) = await _raw(
    base,
    credentials,
    'GET',
    path,
    headers: {'if-none-match': etag},
  );
  return resp.statusCode == 304;
}

Future<String> _rawPropfind(
  Uri base,
  WebDavCredentials credentials,
  String path, {
  required int depth,
}) async {
  final (_, bytes) = await _raw(
    base,
    credentials,
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

Future<int?> _rawMoveProbe(Uri base, WebDavCredentials credentials) async {
  final src = '$_root/tmp/probe-move-src.txt';
  await _raw(base, credentials, 'PUT', src, body: utf8.encode('move-me'));
  final dest = _u(base, '$_root/tmp/probe-move-dst.txt').toString();
  final (resp, _) = await _raw(
    base,
    credentials,
    'MOVE',
    src,
    headers: {'destination': dest, 'overwrite': 'T'},
  );
  await _raw(base, credentials, 'DELETE', src);
  await _raw(base, credentials, 'DELETE', '$_root/tmp/probe-move-dst.txt');
  return resp.statusCode;
}

Future<(bool, String?)> _rawRangeProbe(
  Uri base,
  WebDavCredentials credentials,
  String path,
) async {
  final (resp, _) = await _raw(
    base,
    credentials,
    'GET',
    path,
    headers: {'range': 'bytes=0-0'},
  );
  return (resp.statusCode == 206, resp.headers.value('content-range'));
}

Future<bool> _rawGzipProbe(
  Uri base,
  WebDavCredentials credentials,
  String path,
) async {
  final (resp, _) = await _raw(
    base,
    credentials,
    'GET',
    path,
    headers: {'accept-encoding': 'gzip'},
  );
  return resp.headers.value('content-encoding')?.contains('gzip') ?? false;
}

/// 清理探针正文与 tmp 产物（meta 已由 DELETE 步骤删除）。
Future<void> _cleanupProbeArtifacts(
  Uri base,
  WebDavCredentials credentials,
  String bookId,
) async {
  await _raw(base, credentials, 'DELETE', '$_root/books/$bookId.txt');
  await _raw(base, credentials, 'DELETE', '$_root/tmp/$bookId.txt.part');
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
        '01JGYPROBE${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase().padLeft(10, '0')}',
    rev: 1,
    deviceId: '01JGYPROBEDEVICE00',
    deviceName: 'jianguoyun-probe',
    createdAt: now,
    updatedAt: now,
    book: BookInfo(
      title: '坚果云探针书',
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
