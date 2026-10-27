import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../internal/semaphore.dart';
import '../../model/book_meta.dart';
import '../backend_adapter.dart';
import 'webdav_propfind.dart';
import 'webdav_ulid.dart';

/// WebDAV 适配器（docs/03 §4.3 / docs/04 §8.1；坚果云为第一目标，兼容通用
/// WebDAV）。只使用六个 HTTP 动词：PROPFIND / GET / PUT / MOVE / MKCOL /
/// DELETE；dio 直用，不引入 webdav_client 之类封装（CLAUDE.md §2）。
///
/// ## 目录布局（docs/05 §1）
/// `{baseUrl}{rootPath}/` 下 `library.json`、`meta/{bookId}.json`、
/// `books/{bookId}.{ext}`、`tmp/{bookId}.{ext}.part`；rootPath 默认
/// `/Apps/SyncReader`，逐段 percent-encode（段内 `/` 为分隔符保留）。
///
/// ## stub.rev 的来源（关键设计，docs/04 §4 阶段 1/2 的 WebDAV 约束）
/// PROPFIND 只能看到 etag/size/mtime，**拿不到 meta JSON 里的 rev**；而
/// Diff 引擎按 `stub.rev × baseRev` 生成五类集合、契约用例 2 又要求
/// `stub.rev` 与真实 rev 一致，因此本适配器采用"**两级清单**"：
///
/// 1. PROPFIND Depth:1 一次拿到全部 bookId 的 etag/size/mtime；
/// 2. 实例内维护 `etag → rev` 缓存（由 getMeta / putMeta 的响应 ETag、
///    以及 listMetas 未命中时的一次补拉回填）；etag 由内容决定
///    （强 ETag / size+mtime 合成），内容变则 etag 变，故同一 etag 恒定
///    对应同一 rev；
/// 3. listMetas 时缓存命中的条目**零额外请求**；未命中（首次接入、他端
///    变更、无 ETag 服务器）逐本补拉一次 GET。
///
/// 因此 `stub.rev` 始终是权威值，引擎无需任何 WebDAV 特判；代价是适配器
/// 实例冷启动后的第一次 listMetas 多 N 个 KB 级 GET（R3 可评估引入持久化
/// 清单压缩该成本，见交付报告）。仅当远端 meta 本身损坏（解析失败）时
/// stub.rev 才退化为 0，由引擎按 Corruption 处理（test/engine/
/// webdav_compat_test.dart 覆盖）。
///
/// ## 能力探测与降级（docs/04 §8.1）
/// - `supportsEtag=false`：etag 用 `synthetic-{size}-{mtimeMs}` 合成
///   （[DavEntry.synthetic]），条件请求退化为"200 + etag 相同按 304 处理"；
/// - `supportsMove=false`：上传直写目标位，随后 `Range: bytes=0-0` 校验
///   `Content-Range` 总长（docs/05 §1 原子性脚注）；
/// - `supportsRange`：`Range: bytes=0-0` 期待 206。
///
/// ## 凭据安全（NFR-03）
/// Basic 认证只存在于内存中的请求头；任何异常 message 只含请求路径，
/// `toString()` 不含密码，dio 拦截器对异常携带的 Authorization 脱敏。
class WebDavAdapter implements BackendAdapter {
  WebDavAdapter({
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(minutes: 5),
  });

  /// 连接超时（坚果云跨境链路实测后可调，R3）。
  final Duration connectTimeout;

  /// 响应接收超时（大正文流式下载按块间间隔计）。
  final Duration receiveTimeout;

  @override
  BackendKind get kind => BackendKind.webdav;

  BackendConfig? _config;
  Dio? _dio;
  List<String> _baseSegments = const [];
  List<String> _rootSegments = const ['Apps', 'SyncReader'];

  /// 能力探测结果（实例级缓存，docs/04 §8.1）。
  BackendCapabilities? _capabilities;

  /// etag → rev 缓存（两级清单的第二级，见类注释）。
  final Map<String, int> _revCache = {};

  /// bookId → `books/` 下实际文件名缓存（ext 探测结果）。
  final Map<String, String> _bookFileCache = {};

  /// library.json 原文缓存（契约用例 1 要求两次读取返回同一实例）。
  String? _libraryJsonCache;

  /// listMetas 冷缓存补拉并发上限。
  final Semaphore _listingSlots = Semaphore(4);

  // ── 连接与布局 ────────────────────────────────────────────────────────

  @override
  Future<void> connect(BackendConfig cfg) async {
    if (cfg.kind != BackendKind.webdav) {
      throw ArgumentError('WebDavAdapter 只接受 BackendKind.webdav 配置');
    }
    _config = cfg;
    _dio = _buildDio(cfg);
    final base = Uri.parse(cfg.baseUrl);
    _baseSegments = base.pathSegments.where((s) => s.isNotEmpty).toList();
    final root = cfg.rootPath ?? '/Apps/SyncReader';
    _rootSegments = root
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);

    // 连通性探测：PROPFIND Depth:0 同步根。404 = 根不存在，留给 ensureLayout
    // 创建（不自动建目录，docs/04 §5.2）；凭据/权限问题在此即暴露。
    final resp = await _requestBytes(
      'PROPFIND',
      _uri(''),
      headers: {'depth': '0', 'content-type': 'application/xml; charset=utf-8'},
      data: utf8.encode(buildPropfindBody()),
    );
    switch (resp.statusCode) {
      case 404:
      case 409:
        // 根缺失不算失败。坚果云对不存在目录的 PROPFIND 回 409（非标准
        // 404，R3 实测 2026-10-27），语义同为"父级不存在"，留给
        // ensureLayout 创建（不自动建目录，docs/04 §5.2）。
        return;
      case 401:
      case 403:
        throw AuthFailed(
          '认证失败（HTTP ${resp.statusCode}），'
          '请检查账号与应用密码权限：${_safePath(cfg.baseUrl)}',
        );
      default:
        _throwIfBadStatus(resp, '连接探测');
    }
  }

  @override
  Future<BackendCapabilities> probeCapabilities() async {
    final cached = _capabilities;
    if (cached != null) return cached;

    await _ensureRoot(); // 全新网盘根缺失时探测也要能走通
    await _mkcol(_uri('tmp')); // 405 已存在视为成功

    final probe = 'sync-reader-probe-${DateTime.now().microsecondsSinceEpoch}';
    var supportsEtag = false;
    var supportsMove = false;
    var supportsRange = false;
    try {
      final putResp = await _requestBytes(
        'PUT',
        _uri('tmp/$probe'),
        data: utf8.encode('sync-reader-probe'),
        contentType: 'application/octet-stream',
      );
      _throwIfBadStatus(putResp, '能力探测 PUT');
      final getResp = await _requestBytes('GET', _uri('tmp/$probe'));
      _throwIfBadStatus(getResp, '能力探测 GET');
      final entries = await _propfind(_uri('tmp/$probe'), depth: 0);
      final hasEtagProp = entries.isNotEmpty && entries.first.etag != null;
      supportsEtag = getResp.headers.value('etag') != null && hasEtagProp;

      // MOVE 探测：任何失败都只降级为 supportsMove=false（坚果云禁 MOVE
      // 表现为 403，属能力缺失而非认证问题，docs/05 §1）。
      try {
        final moveResp = await _requestBytes(
          'MOVE',
          _uri('tmp/$probe'),
          headers: {
            'destination': _uri('tmp/$probe-moved').toString(),
            'overwrite': 'T',
          },
        );
        final moveStatus = moveResp.statusCode;
        supportsMove =
            moveStatus != null && moveStatus >= 200 && moveStatus < 300;
      } on Object {
        supportsMove = false;
      }

      final rangeResp = await _requestBytes(
        'GET',
        _uri('tmp/${supportsMove ? '$probe-moved' : probe}'),
        headers: {'range': 'bytes=0-0'},
      );
      supportsRange = rangeResp.statusCode == 206;
    } finally {
      // 探测文件清理（尽力而为，失败不影响能力结论）。
      for (final p in ['tmp/$probe', 'tmp/$probe-moved']) {
        try {
          final resp = await _requestBytes('DELETE', _uri(p));
          if (resp.statusCode != 404) _throwIfBadStatus(resp, '探测清理');
        } on Object {
          // 忽略清理失败。
        }
      }
    }
    return _capabilities = BackendCapabilities(
      supportsMove: supportsMove,
      supportsEtag: supportsEtag,
      supportsRange: supportsRange,
    );
  }

  @override
  Future<void> ensureLayout() async {
    await _ensureRoot();
    for (final dir in const ['meta', 'books', 'tmp']) {
      final resp = await _requestBytes(
        'PROPFIND',
        _uri(dir),
        headers: {
          'depth': '0',
          'content-type': 'application/xml; charset=utf-8',
        },
        data: utf8.encode(buildPropfindBody()),
      );
      if (_isMissingStatus(resp.statusCode)) {
        await _mkcol(_uri(dir)); // 405 已存在视为成功
      } else {
        _throwIfBadStatus(resp, 'ensureLayout 探测 $dir/');
      }
    }

    // library.json：已存在且可解析则不覆盖（幂等且不破坏他端写入的
    // libraryId）；缺失时 PUT 带 If-None-Match: * 防两设备首连竞态双写；
    // 存在但损坏 → 直接重写。
    final libResp = await _requestBytes('GET', _uri('library.json'));
    switch (libResp.statusCode) {
      case 200:
        final body = utf8.decode(libResp.data ?? const []);
        if (_parsableLibrary(body)) {
          _libraryJsonCache ??= body;
          return;
        }
        await _putLibraryJson(guardCreate: false);
      case 404:
        await _putLibraryJson(guardCreate: true);
      default:
        _throwIfBadStatus(libResp, 'ensureLayout 读取 library.json');
    }
  }

  Future<void> _putLibraryJson({required bool guardCreate}) async {
    final payload = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'libraryId': newUlid(),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    final putResp = await _requestBytes(
      'PUT',
      _uri('library.json'),
      data: payload,
      contentType: 'application/json',
      headers: guardCreate ? {'if-none-match': '*'} : null,
    );
    if (putResp.statusCode == 412) {
      // 并发首连竞态输家：复用赢家写入的 libraryId。
      _libraryJsonCache = null;
      await _readLibraryRaw();
      return;
    }
    _throwIfBadStatus(putResp, 'ensureLayout 写 library.json');
    _libraryJsonCache = null; // 下次读取回填新内容
  }

  @override
  Future<String?> readLibraryJson() async => _readLibraryRaw();

  /// 确保同步根（含用户自定义多级父目录）存在；幂等。
  Future<void> _ensureRoot() async {
    final resp = await _requestBytes(
      'PROPFIND',
      _uri(''),
      headers: {'depth': '0', 'content-type': 'application/xml; charset=utf-8'},
      data: utf8.encode(buildPropfindBody()),
    );
    if (!_isMissingStatus(resp.statusCode)) {
      _throwIfBadStatus(resp, 'ensureLayout 探测根目录');
      return;
    }
    // 根缺失：逐级 MKCOL（坚果云 /Apps/ 由官方预留已存在，通用服务器可能
    // 连父级都没有）。
    for (var i = 1; i <= _rootSegments.length; i++) {
      await _mkcol(_rootUri(i));
    }
  }

  /// "资源不存在"的返回码集合。坚果云对不存在目录的 PROPFIND 回 409
  /// （非标准 404，R3 实测 2026-10-27），语义同为缺失。
  static bool _isMissingStatus(int? statusCode) =>
      statusCode == 404 || statusCode == 409;

  Future<void> _mkcol(Uri uri) async {
    final resp = await _requestBytes('MKCOL', uri);
    // 405 = 已存在（幂等成功）；201/204 = 新建。
    if (resp.statusCode == 405) return;
    _throwIfBadStatus(resp, '创建目录 ${_safePath(uri.toString())}');
  }

  Future<String?> _readLibraryRaw() async {
    if (_libraryJsonCache != null) return _libraryJsonCache;
    final resp = await _requestBytes('GET', _uri('library.json'));
    switch (resp.statusCode) {
      case 404:
        return null;
      case 200:
        // 返回原文（损坏与否由调用方判定，docs/03 §4.3 readLibraryJson 语义）。
        return _libraryJsonCache = utf8.decode(resp.data ?? const []);
      default:
        _throwIfBadStatus(resp, '读取 library.json');
        return null;
    }
  }

  static bool _parsableLibrary(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map &&
          json['libraryId'] is String &&
          (json['libraryId'] as String).isNotEmpty;
    } on FormatException {
      return false;
    }
  }

  // ── 清单与元数据 ──────────────────────────────────────────────────────

  @override
  Future<MetaListing> listMetas({String? cursor}) async {
    // WebDAV 无服务端游标：全量 PROPFIND + ETag 比对（docs/04 §2 cursor 行）。
    final entries = await _propfind(_uri('meta'), depth: 1);
    final stubs = <String, RemoteMetaStub>{};
    final pending = <String, (DavEntry, String)>{};
    for (final entry in entries) {
      if (entry.isDir) continue;
      final name = entry.name;
      if (!name.endsWith('.json') || name.length <= 5) continue;
      final bookId = name.substring(0, name.length - 5);
      final etag = entry.etag ?? DavEntry.synthetic(entry.size, entry.modified);
      final cached = _revCache[etag];
      if (cached != null) {
        stubs[bookId] = _stubOf(bookId, entry, etag, cached);
      } else {
        pending[bookId] = (entry, etag); // 冷缓存补拉（见类注释）
      }
    }
    if (pending.isNotEmpty) {
      await Future.wait([
        for (final e in pending.entries)
          _listingSlots.run(() async {
            final (entry, etag) = e.value;
            final rev = await _revByGet(e.key, etag);
            if (rev == null) return; // 清单与 GET 之间文件被删 → 不进清单
            stubs[e.key] = _stubOf(e.key, entry, etag, rev);
          }),
      ]);
    }
    return MetaListing(stubs: stubs);
  }

  RemoteMetaStub _stubOf(String bookId, DavEntry entry, String etag, int rev) =>
      RemoteMetaStub(
        bookId: bookId,
        rev: rev,
        etag: etag,
        size: entry.size,
        modifiedAt: entry.modified,
      );

  /// 补拉单本 meta 取权威 rev（两级清单的冷缓存路径）。
  /// 返回 null = 文件已消失；解析失败缓存 rev=0（引擎按 Corruption 处理）。
  Future<int?> _revByGet(String bookId, String etag) async {
    final resp = await _requestBytes('GET', _uri('meta/$bookId.json'));
    switch (resp.statusCode) {
      case 404:
        return null;
      case 200:
        try {
          final meta = BookMeta.fromJsonString(
            utf8.decode(resp.data ?? const []),
          );
          _revCache[etag] = meta.rev;
          return meta.rev;
        } on FormatException {
          _revCache[etag] = 0;
          return 0;
        }
      default:
        _throwIfBadStatus(resp, '清单补拉 $bookId');
        return null;
    }
  }

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) async {
    final resp = await _requestBytes(
      'GET',
      _uri('meta/$bookId.json'),
      headers: ifNoneMatch == null ? null : {'if-none-match': ifNoneMatch},
    );
    switch (resp.statusCode) {
      case 304:
        return null; // 条件请求命中（docs/04 §4 阶段 3）
      case 404:
        return null; // 引擎按远端缺失处理
      case 200:
        final meta = BookMeta.fromJsonString(
          utf8.decode(resp.data ?? const []),
        );
        final etag =
            resp.headers.value('etag') ??
            DavEntry.synthetic(
              _headerInt(resp, 'content-length'),
              _headerDate(resp, 'last-modified'),
            );
        _revCache[etag] = meta.rev;
        // 服务器不支持 304 时的兜底：200 但内容未变（etag 相同）按未变更处理。
        if (ifNoneMatch != null && etagEquals(etag, ifNoneMatch)) return null;
        return meta;
      default:
        _throwIfBadStatus(resp, '读取 meta $bookId');
        return null;
    }
  }

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) =>
      _putMetaLocked(meta, expectedRev: expectedRev);

  @override
  Future<void> putTombstone(
    BookMeta tombstoned, {
    required int expectedRev,
  }) async {
    if (!tombstoned.isTombstone) {
      throw ArgumentError('putTombstone 需要 deleted=true 的 meta');
    }
    await _putMetaLocked(tombstoned, expectedRev: expectedRev);
  }

  /// WebDAV 无 CAS → 写前重读（docs/03 §4.3）：当前 rev 与 expectedRev 不符
  /// 抛 [RevConflict]（语义与 REST 409 一致，供引擎走合并流程）。
  Future<void> _putMetaLocked(BookMeta meta, {required int expectedRev}) async {
    final currentResp = await _requestBytes(
      'GET',
      _uri('meta/${meta.bookId}.json'),
    );
    BookMeta? current;
    switch (currentResp.statusCode) {
      case 200:
        current = BookMeta.fromJsonString(
          utf8.decode(currentResp.data ?? const []),
        );
      case 404:
        current = null;
      default:
        _throwIfBadStatus(currentResp, '写前重读 ${meta.bookId}');
    }
    final currentRev = current?.rev ?? 0;
    if (currentRev != expectedRev) {
      throw RevConflict(meta.bookId, currentRev, current);
    }
    // 重读结果回填缓存（etag 由内容决定 → etag→rev 映射成立）。
    final currentEtag = currentResp.headers.value('etag');
    if (currentEtag != null) _revCache[currentEtag] = currentRev;

    final putResp = await _requestBytes(
      'PUT',
      _uri('meta/${meta.bookId}.json'),
      data: utf8.encode(meta.toJsonString()),
      contentType: 'application/json',
    );
    _throwIfBadStatus(putResp, '写入 meta ${meta.bookId}');
    final respEtag = putResp.headers.value('etag');
    if (respEtag != null) _revCache[respEtag] = meta.rev;
  }

  @override
  Future<void> deleteMeta(String bookId) async {
    final resp = await _requestBytes('DELETE', _uri('meta/$bookId.json'));
    if (resp.statusCode == 404) return; // 幂等（docs/04 §7.3 GC 专用）
    _throwIfBadStatus(resp, '删除 meta $bookId');
  }

  @override
  Future<List<CloudBookFile>> listBookFiles() async {
    // PROPFIND Depth:1：目录缺失（首次同步前）由 _propfind 回空表
    // （坚果云对缺失目录回 409，_isMissingStatus 已兼容）。
    final entries = await _propfind(_uri('books'), depth: 1);
    return [
      for (final entry in entries)
        if (!entry.isDir && entry.name.isNotEmpty)
          CloudBookFile(name: entry.name, sizeBytes: entry.size ?? 0),
    ];
  }

  @override
  Future<void> deleteBookFile(String name) async {
    // name 为 books/ 下的文件名（{bookId}.{ext}）；_uri 逐段 percent-encode。
    final resp = await _requestBytes('DELETE', _uri('books/$name'));
    if (resp.statusCode == 404) return; // 幂等成功（契约语义）
    _throwIfBadStatus(resp, '删除云端正文 $name');
  }

  // ── 正文传输 ──────────────────────────────────────────────────────────

  @override
  Future<void> uploadBook(
    String bookId,
    File file,
    String contentHash, {
    bool overwrite = false,
  }) async {
    final ext = _extOf(file.path);
    final name = '$bookId.$ext';
    final localSize = await file.length();

    // 先流式算本地 SHA-256：与声明 contentHash 不符 → 拒收（契约用例 6）。
    final digest = (await sha256.bind(file.openRead()).first).toString();
    final claimed = _normalizeHash(contentHash);
    if (digest != claimed) {
      throw ContentHashMismatch(bookId, '上传内容实际哈希 $digest 与声明 $claimed 不符');
    }

    // 查重：远端已有同内容文件 → 跳过上传（幂等，docs/04 §5.3）。
    // FR-410 显式替换（overwrite=true）跳过"已有不同版本"检查，直接覆盖；
    // 同 hash 幂等跳过的判定仍保留（替换到相同内容是无害 no-op）。
    if (!overwrite) {
      final prop = await _propfindOne(_uri('books/$name'));
      if (prop != null) {
        final remoteEtag = prop.etag == null ? null : _stripEtag(prop.etag!);
        if (remoteEtag != null && _isMd5Hex(remoteEtag)) {
          // 坚果云等 etag=MD5 的服务器：免下载判定。
          final localMd5 = (await md5.bind(file.openRead()).first).toString();
          if (remoteEtag == localMd5) return;
          throw ContentHashMismatch(bookId, '远端已存在不同版本的正文（etag 不符）');
        }
        if (prop.size != null && prop.size != localSize) {
          throw ContentHashMismatch(
            bookId,
            '远端已存在不同版本的正文（尺寸 ${prop.size} ≠ 本地 $localSize）',
          );
        }
        // 尺寸相等（或服务器不报尺寸）且无法凭 etag 判定 → 下载比对收尾，
        // 与内存参考实现的哈希语义对齐（仅同尺寸歧义场景付出此流量）。
        final remoteHash = await _hashRemote(_uri('books/$name'));
        if (remoteHash == digest) return;
        throw ContentHashMismatch(bookId, '远端已存在不同版本的正文（哈希不符）');
      }
    }

    final capabilities = await probeCapabilities();
    if (capabilities.supportsMove) {
      final part = _uri('tmp/$name.part');
      final putResp = await _requestBytes(
        'PUT',
        part,
        data: file.openRead(),
        contentType: 'application/octet-stream',
        headers: {'content-length': '$localSize'},
      );
      _throwIfBadStatus(putResp, '上传正文暂存 $name');
      try {
        final moveResp = await _requestBytes(
          'MOVE',
          part,
          headers: {
            'destination': _uri('books/$name').toString(),
            'overwrite': 'T',
          },
        );
        _throwIfBadStatus(moveResp, '提交正文 $name');
      } on Object {
        // MOVE 失败尽力清理暂存，异常原样上抛（可重试）。
        try {
          await _requestBytes('DELETE', part);
        } on Object {
          // 忽略清理失败。
        }
        rethrow;
      }
    } else {
      // 无 MOVE 的网盘：直写目标位 + Content-Length 校验兜底（docs/05 §1）。
      final putResp = await _requestBytes(
        'PUT',
        _uri('books/$name'),
        data: file.openRead(),
        contentType: 'application/octet-stream',
        headers: {'content-length': '$localSize'},
      );
      _throwIfBadStatus(putResp, '上传正文 $name');
      if (localSize > 0) {
        final verified = await _verifyUploadedSize(
          _uri('books/$name'),
          localSize,
        );
        if (!verified) {
          throw BackendRequestException('上传后校验不符：$name 远端尺寸与本地 $localSize 不一致');
        }
      }
    }
    _bookFileCache[bookId] = name;
  }

  /// Range: bytes=0-0 探测远端总长与本地比对；不支持 Range 的服务器退化为
  /// 全量下载计数（罕见组合，正确性优先）。
  Future<bool> _verifyUploadedSize(Uri uri, int localSize) async {
    final resp = await _requestStream(uri, headers: {'range': 'bytes=0-0'});
    switch (resp.statusCode) {
      case 206:
        final total = _totalFromContentRange(
          resp.headers.value('content-range'),
        );
        return total == null || total == localSize;
      case 200:
        var count = 0;
        await for (final chunk in (resp.data as ResponseBody).stream) {
          count += chunk.length;
        }
        return count == localSize;
      default:
        return false;
    }
  }

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) async* {
    final name = await _resolveBookFile(bookId);
    final headers = <String, String>{};
    if (startByte != null && startByte > 0) {
      headers['range'] = 'bytes=$startByte-';
    }
    final resp = await _requestStream(_uri('books/$name'), headers: headers);
    switch (resp.statusCode) {
      case 200:
      case 206:
        final body = resp.data as ResponseBody;
        if (resp.statusCode == 206 || startByte == null || startByte <= 0) {
          yield* body.stream.cast<List<int>>();
        } else {
          // 服务器不支持 Range（返回 200 全量）→ 本地丢弃前 startByte 字节。
          yield* _skipBytes(body.stream.cast<List<int>>(), startByte);
        }
      case 404:
        throw BackendRequestException('云端正文不存在：$bookId', statusCode: 404);
      case 416:
        return; // 起点越界 = 无剩余字节（与内存实现 clamp 语义一致）
      default:
        _throwIfBadStatus(resp, '下载正文 $bookId');
    }
  }

  /// 解析 `books/{bookId}.{ext}` 实际文件名：先试常见扩展名（Range 探测
  /// 单字节，代价可忽略），未命中再 PROPFIND Depth:1 兜底（自由扩展名）。
  Future<String> _resolveBookFile(String bookId) async {
    final cached = _bookFileCache[bookId];
    if (cached != null) return cached;
    for (final ext in const ['epub', 'txt', 'md', 'pdf', 'bin']) {
      final resp = await _requestStream(
        _uri('books/$bookId.$ext'),
        headers: {'range': 'bytes=0-0'},
      );
      switch (resp.statusCode) {
        case 200:
        case 206:
          // 消耗探测连接后再走正式下载。
          await (resp.data as ResponseBody).stream.drain<void>();
          return _bookFileCache[bookId] = '$bookId.$ext';
        case 404:
          continue;
        default:
          _throwIfBadStatus(resp, '定位正文 $bookId');
      }
    }
    // 自由扩展名兜底：列 books/ 前缀匹配。
    final entries = await _propfind(_uri('books'), depth: 1);
    for (final entry in entries) {
      if (entry.isDir) continue;
      if (entry.name == bookId || entry.name.startsWith('$bookId.')) {
        return _bookFileCache[bookId] = entry.name;
      }
    }
    throw BackendRequestException('云端正文不存在：$bookId', statusCode: 404);
  }

  // ── 生命周期 ──────────────────────────────────────────────────────────

  @override
  Future<void> dispose() async {
    _dio?.close(force: true);
    _dio = null;
  }

  @override
  String toString() =>
      'WebDavAdapter(${_config?.baseUrl ?? 'disconnected'}, '
      'root=${_config?.rootPath ?? '/Apps/SyncReader'})'; // 永不含凭据

  // ── HTTP 基础设施 ──────────────────────────────────────────────────────

  Dio _buildDio(BackendConfig cfg) {
    final dio = Dio(
      BaseOptions(
        // 状态码由适配器统一映射（backend_adapter.dart 错误总表），
        // 不依赖 dio 的 badResponse 异常分流。
        validateStatus: (_) => true,
        responseType: ResponseType.bytes,
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final user = cfg.username;
          final pass = cfg.password ?? '';
          if (user != null) {
            options.headers[HttpHeaders.authorizationHeader] =
                'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
          }
          handler.next(options);
        },
        onError: (e, handler) {
          // 凭据脱敏：异常对象携带的请求选项不得含明文 Authorization（NFR-03）。
          final headers = e.requestOptions.headers;
          if (headers.containsKey(HttpHeaders.authorizationHeader)) {
            headers[HttpHeaders.authorizationHeader] = 'Basic ***';
          }
          handler.next(e);
        },
      ),
    );
    return dio;
  }

  Future<Response<List<int>>> _requestBytes(
    String method,
    Uri uri, {
    Object? data,
    Map<String, String>? headers,
    String? contentType,
  }) async {
    try {
      return await _dio!.request<List<int>>(
        uri.toString(),
        data: data,
        options: Options(
          method: method,
          headers: headers,
          contentType: contentType,
        ),
      );
    } on DioException catch (e) {
      throw _networkError(e, uri);
    } on SocketException catch (e) {
      throw _networkError(e, uri);
    } on TimeoutException catch (e) {
      throw _networkError(e, uri);
    }
  }

  Future<Response<ResponseBody>> _requestStream(
    Uri uri, {
    Map<String, String>? headers,
  }) async {
    try {
      return await _dio!.request<ResponseBody>(
        uri.toString(),
        options: Options(
          method: 'GET',
          headers: headers,
          responseType: ResponseType.stream,
        ),
      );
    } on DioException catch (e) {
      throw _networkError(e, uri);
    } on SocketException catch (e) {
      throw _networkError(e, uri);
    } on TimeoutException catch (e) {
      throw _networkError(e, uri);
    }
  }

  /// PROPFIND Depth:0 单资源；404 返回 null。
  Future<DavEntry?> _propfindOne(Uri uri) async {
    final entries = await _propfind(uri, depth: 0);
    return entries.isEmpty ? null : entries.first;
  }

  /// PROPFIND；404（目录不存在）返回空表。
  Future<List<DavEntry>> _propfind(Uri uri, {required int depth}) async {
    final resp = await _requestBytes(
      'PROPFIND',
      uri,
      headers: {
        'depth': '$depth',
        'content-type': 'application/xml; charset=utf-8',
      },
      data: utf8.encode(buildPropfindBody()),
    );
    if (_isMissingStatus(resp.statusCode)) return const [];
    _throwIfBadStatus(resp, 'PROPFIND ${_safePath(uri.toString())}');
    final body = utf8.decode(resp.data ?? const []);
    return parseMultistatus(body);
  }

  // ── 错误映射（backend_adapter.dart 错误总表，docs/04 §8.4）──────────────

  void _throwIfBadStatus(Response<dynamic> resp, String context) {
    final status = resp.statusCode;
    if (status != null && status >= 200 && status < 300) return;
    final uri = resp.requestOptions.uri;
    if (status == 401 || status == 403) {
      throw AuthFailed(
        '认证失败（HTTP $status），请检查账号与应用密码权限'
        '（403 需确认应用密码已勾选目录权限）：${_safePath(uri.toString())}',
      );
    }
    throw BackendRequestException(
      '$context 失败（HTTP $status）：${_safePath(uri.toString())}',
      statusCode: status,
      retryAfter: _parseRetryAfter(resp.headers.value('retry-after')),
    );
  }

  BackendRequestException _networkError(Object e, Uri uri) =>
      BackendRequestException(
        '网络异常：${_safePath(uri.toString())}',
        statusCode: null,
        cause: e,
      );

  /// 解析 `Retry-After`：支持秒数与 HTTP 日期两种格式（docs/04 §8.4）。
  static Duration? _parseRetryAfter(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;
    final seconds = int.tryParse(value);
    if (seconds != null) {
      return Duration(seconds: seconds < 0 ? 0 : seconds);
    }
    try {
      final date = HttpDate.parse(value);
      final delta = date.difference(DateTime.now().toUtc());
      return delta.isNegative ? Duration.zero : delta;
    } on FormatException {
      return null;
    }
  }

  // ── 工具 ──────────────────────────────────────────────────────────────

  /// 拼接 `{baseUrl}{rootPath}/{subPath}`：逐段自动 percent-encode
  /// （bookId 为 ULID 安全，rootPath 用户可自定义；段内 `/` 为分隔符保留）。
  Uri _uri(String subPath) {
    final base = Uri.parse(_config!.baseUrl);
    final subs = subPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      pathSegments: [..._baseSegments, ..._rootSegments, ...subs],
      // 凭据禁止进 URL：Basic 认证只走请求头（NFR-03）。
    );
  }

  /// 逐级 MKCOL 的根前缀 URI（i = 1..length）。
  Uri _rootUri(int level) {
    final base = Uri.parse(_config!.baseUrl);
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.port,
      pathSegments: [..._baseSegments, ..._rootSegments.take(level)],
    );
  }

  /// 异常/日志安全路径：剥离查询串（防御性，凭据本就不进 URL）。
  static String _safePath(String url) {
    final uri = Uri.tryParse(url);
    return uri == null ? url : uri.path;
  }

  /// 远端文件整体下载并计算 SHA-256（同尺寸查重的收尾比对）。
  Future<String> _hashRemote(Uri uri) async {
    final resp = await _requestStream(uri);
    if (resp.statusCode != 200 && resp.statusCode != 206) {
      throw BackendRequestException(
        '查重下载失败（HTTP ${resp.statusCode}）：${_safePath(uri.toString())}',
        statusCode: resp.statusCode,
      );
    }
    final digest = await sha256.bind((resp.data as ResponseBody).stream).first;
    return digest.toString();
  }

  /// 丢弃流的前 [n] 字节（服务器不支持 Range 时的本地续传切片）。
  Stream<List<int>> _skipBytes(Stream<List<int>> source, int n) async* {
    var remaining = n;
    await for (final chunk in source) {
      if (remaining <= 0) {
        yield chunk;
        continue;
      }
      if (chunk.length <= remaining) {
        remaining -= chunk.length;
        continue;
      }
      yield chunk.sublist(remaining);
      remaining = 0;
    }
  }

  /// Content-Range: `bytes 0-0/12345` → 12345。
  static int? _totalFromContentRange(String? raw) {
    if (raw == null) return null;
    final slash = raw.lastIndexOf('/');
    if (slash < 0 || slash == raw.length - 1) return null;
    final total = raw.substring(slash + 1).trim();
    if (total == '*') return null;
    return int.tryParse(total);
  }

  static int? _headerInt(Response<List<int>> resp, String name) {
    final v = resp.headers.value(name);
    return v == null ? null : int.tryParse(v.trim());
  }

  static DateTime? _headerDate(Response<List<int>> resp, String name) {
    final v = resp.headers.value(name);
    if (v == null) return null;
    try {
      return HttpDate.parse(v).toUtc();
    } on FormatException {
      return null;
    }
  }

  /// etag 归一化比较：剥 `W/` 与引号（不同服务器引号风格不一）。
  static bool etagEquals(String? a, String? b) {
    if (a == null || b == null) return false;
    return _stripEtag(a) == _stripEtag(b);
  }

  static String _stripEtag(String etag) {
    var v = etag.trim();
    if (v.startsWith('W/')) v = v.substring(2);
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v;
  }

  /// `sha256:<hex>` / 裸 hex → 小写 hex。
  static String _normalizeHash(String contentHash) {
    var v = contentHash.trim().toLowerCase();
    if (v.startsWith('sha256:')) v = v.substring('sha256:'.length);
    return v;
  }

  static final RegExp _md5HexPattern = RegExp(r'^[0-9a-fA-F]{32}$');

  static bool _isMd5Hex(String v) => _md5HexPattern.hasMatch(v);

  static String _extOf(String path) {
    final base = path.replaceAll('\\', '/');
    final dot = base.lastIndexOf('.');
    final slash = base.lastIndexOf('/');
    return (dot > slash && dot >= 0) ? base.substring(dot + 1) : 'bin';
  }
}
