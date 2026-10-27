import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import '../../model/book_meta.dart';
import '../backend_adapter.dart';

/// [BackendAdapter] 的内存参考实现：契约语义的"第二实现"。
///
/// 供契约套件默认执行（CI 无网安全）、引擎测试与 app 测试复用。
/// 目录模型与 etag 语义与真实 WebDAV 适配器保持一致（docs/05 §1）：
/// - `library.json / meta/{bookId}.json / books/{bookId}.{ext} / tmp/`；
/// - etag = meta JSON 内容短摘要（写即变，If-None-Match 命中返回 304）；
/// - putMeta 写前重读：`expectedRev` 与存储不符抛 [RevConflict]；
/// - uploadBook：同 hash 跳过（幂等）、hash 不符抛 [ContentHashMismatch]；
/// - downloadBook 支持 Range（startByte）切片。
class InMemoryAdapter implements BackendAdapter {
  @override
  BackendKind get kind => BackendKind.webdav;

  /// 内存目录：meta 文件（bookId → JSON 原文）。
  final Map<String, String> metas = {};

  /// 正文文件（文件名 `bookId.ext` → 字节）。
  final Map<String, Uint8List> books = {};

  /// 上传暂存区 `tmp/`（暴露 MOVE 过程，断言用）。
  final Map<String, Uint8List> tmp = {};

  bool _layoutExists = false;
  String? _libraryJson;

  /// connect 时保存的配置（诊断用）。
  BackendConfig? get config => _config;
  BackendConfig? _config;

  // ── 诊断计数（测试断言用）──
  int getMetaCalls = 0;
  int conditionalNotModified = 0;
  int putMetaCalls = 0;
  int deleteMetaCalls = 0;
  int uploadCalls = 0;
  int skippedUploads = 0;
  int activeDownloads = 0;
  int peakDownloads = 0;

  @override
  Future<void> connect(BackendConfig cfg) async {
    _config = cfg;
  }

  @override
  Future<BackendCapabilities> probeCapabilities() async =>
      const BackendCapabilities(
        supportsMove: true,
        supportsEtag: true,
        supportsRange: true,
      );

  @override
  Future<void> ensureLayout() async {
    if (_layoutExists) return; // 幂等：已存在即跳过
    _layoutExists = true;
    _libraryJson ??= jsonEncode({
      'schemaVersion': 1,
      'libraryId': '01INMEMORYLIB',
      'createdAt': '2026-10-26T00:00:00.000Z',
    });
  }

  @override
  Future<String?> readLibraryJson() async => _libraryJson;

  @override
  Future<MetaListing> listMetas({String? cursor}) async {
    final stubs = <String, RemoteMetaStub>{};
    for (final entry in metas.entries) {
      final meta = BookMeta.fromJsonString(entry.value);
      stubs[meta.bookId] = RemoteMetaStub(
        bookId: meta.bookId,
        rev: meta.rev,
        etag: _etagOf(entry.value),
        size: utf8.encode(entry.value).length,
        deleted: meta.isTombstone,
      );
    }
    return MetaListing(stubs: stubs, cursor: cursor, hasMore: false);
  }

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) async {
    getMetaCalls++;
    final raw = metas[bookId];
    if (raw == null) return null;
    if (ifNoneMatch != null && ifNoneMatch == _etagOf(raw)) {
      conditionalNotModified++; // 304 语义
      return null;
    }
    return BookMeta.fromJsonString(raw);
  }

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) async {
    putMetaCalls++;
    await _putLocked(meta, expectedRev: expectedRev);
  }

  @override
  Future<void> putTombstone(
    BookMeta tombstoned, {
    required int expectedRev,
  }) async {
    putMetaCalls++;
    if (!tombstoned.isTombstone) {
      throw ArgumentError('putTombstone 需要 deleted=true 的 meta');
    }
    await _putLocked(tombstoned, expectedRev: expectedRev);
  }

  Future<void> _putLocked(BookMeta meta, {required int expectedRev}) async {
    final raw = metas[meta.bookId];
    final currentRev = raw == null ? 0 : BookMeta.fromJsonString(raw).rev;
    // 写前重读：落后即冲突（WebDAV 无 CAS，语义靠读后写对齐，docs/03 §4.3）。
    if (currentRev != expectedRev) {
      throw RevConflict(
        meta.bookId,
        currentRev,
        raw == null ? null : BookMeta.fromJsonString(raw),
      );
    }
    // 模拟 tmp/ → 原子提交。
    tmp['${meta.bookId}.json'] = Uint8List.fromList(
      utf8.encode(meta.toJsonString()),
    );
    metas[meta.bookId] = meta.toJsonString();
    tmp.remove('${meta.bookId}.json');
  }

  @override
  Future<void> deleteMeta(String bookId) async {
    deleteMetaCalls++;
    metas.remove(bookId);
  }

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) async* {
    activeDownloads++;
    if (activeDownloads > peakDownloads) peakDownloads = activeDownloads;
    try {
      final name = _findBookEntryName(bookId);
      if (name == null) {
        throw BackendRequestException('云端正文不存在：$bookId', statusCode: 404);
      }
      final data = books[name]!;
      // Range 切片：从 startByte 起的剩余字节（docs/04 §8.2）。
      final from = (startByte ?? 0).clamp(0, data.length).toInt();
      if (from < data.length) {
        yield data.sublist(from);
      }
    } finally {
      activeDownloads--;
    }
  }

  @override
  Future<void> uploadBook(String bookId, File file, String contentHash) async {
    uploadCalls++;
    final bytes = await file.readAsBytes();
    // contentHash 语义 = `sha256:<hex>`（docs/05 §3.2），适配器侧重算校验。
    final claimed = _sha256Hex(bytes);
    final claimedNorm = contentHash.startsWith('sha256:')
        ? contentHash.substring('sha256:'.length).toLowerCase()
        : contentHash.toLowerCase();
    if (claimed != claimedNorm) {
      // 上传内容实际哈希与声明不符：客户端缺陷，拒收。
      throw ContentHashMismatch(
        bookId,
        '上传内容实际哈希 $claimed 与声明 $claimedNorm 不符',
      );
    }
    final name = _findBookEntryName(bookId) ?? '$bookId.${_extOf(file.path)}';
    final existing = books[name];
    if (existing != null) {
      final existingHash = _sha256Hex(existing);
      if (existingHash == claimedNorm) {
        skippedUploads++; // 幂等：同 hash 跳过（docs/04 §5.3）
        return;
      }
      throw ContentHashMismatch(
        bookId,
        '远端已存在不同版本的正文（$existingHash ≠ $claimedNorm）',
      );
    }
    // tmp/ → MOVE 原子提交（docs/05 §1）。
    tmp['$name.part'] = bytes;
    books[name] = bytes;
    tmp.remove('$name.part');
  }

  @override
  Future<void> dispose() async {}

  // ── 测试辅助 ──

  /// 直接投喂正文字节（模拟他端上传的内容）。
  void putContent(String bookId, String ext, List<int> bytes) {
    books['$bookId.$ext'] = Uint8List.fromList(bytes);
  }

  /// 读正文（断言用）；不存在返回 null。
  Uint8List? contentOf(String bookId) {
    final name = _findBookEntryName(bookId);
    return name == null ? null : books[name];
  }

  String? _findBookEntryName(String bookId) {
    for (final name in books.keys) {
      if (name == bookId || name.startsWith('$bookId.')) return name;
    }
    return null;
  }

  /// etag = 内容短摘要（真实适配器为 SHA-256 前缀或 size+mtime 合成）。
  static String _etagOf(String raw) => 'w/${_shortHash(utf8.encode(raw))}';

  /// 正文内容哈希：`sha256:<hex>` 的 hex 部分（docs/05 §3.2）。
  static String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

  /// FNV-1a 64 位摘要（仅 etag 用）。
  static String _shortHash(List<int> bytes) {
    var hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static String _extOf(String path) {
    final base = path.replaceAll('\\', '/');
    final dot = base.lastIndexOf('.');
    final slash = base.lastIndexOf('/');
    return (dot > slash && dot >= 0) ? base.substring(dot + 1) : 'bin';
  }
}
