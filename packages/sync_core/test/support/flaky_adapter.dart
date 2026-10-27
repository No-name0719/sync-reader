import 'dart:io';

import 'package:sync_core/sync_core.dart';

import 'fixtures.dart';

/// 可编程故障注入适配器：包装 [InMemoryAdapter]，按脚本注入传输层异常
/// （§8.4 重试表测试用）。
class FlakyAdapter implements BackendAdapter {
  FlakyAdapter(this.inner);

  final InMemoryAdapter inner;

  /// putMeta 故障脚本：bookId → 依次抛出的异常工厂（弹尽后放行）。
  final Map<String, List<Object Function()>> putMetaFailures = {};

  /// uploadBook 故障脚本（队列层重试测试用）。
  final List<Object Function()> uploadFailures = [];

  /// 下载"部分数据后断网"的一次性注入（Range 续传测试用）。
  int? failDownloadAfterBytes;

  // ── 诊断计数 ──
  int putMetaAttempts = 0;
  int uploadAttempts = 0;
  int listMetasCalls = 0;
  final List<int?> downloadStartBytes = [];
  int getMetaActive = 0;
  int getMetaPeak = 0;
  Duration getMetaDelay = Duration.zero;

  @override
  BackendKind get kind => inner.kind;

  @override
  Future<void> connect(BackendConfig cfg) => inner.connect(cfg);

  @override
  Future<BackendCapabilities> probeCapabilities() => inner.probeCapabilities();

  @override
  Future<void> ensureLayout() => inner.ensureLayout();

  @override
  Future<String?> readLibraryJson() => inner.readLibraryJson();

  @override
  Future<void> deleteMeta(String bookId) => inner.deleteMeta(bookId);

  @override
  Future<MetaListing> listMetas({String? cursor}) {
    listMetasCalls++;
    return inner.listMetas(cursor: cursor);
  }

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) async {
    getMetaActive++;
    if (getMetaActive > getMetaPeak) getMetaPeak = getMetaActive;
    try {
      if (getMetaDelay > Duration.zero) {
        await Future<void>.delayed(getMetaDelay);
      }
      return await inner.getMeta(bookId, ifNoneMatch: ifNoneMatch);
    } finally {
      getMetaActive--;
    }
  }

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) async {
    putMetaAttempts++;
    final script = putMetaFailures[meta.bookId];
    if (script != null && script.isNotEmpty) {
      throw script.removeAt(0)();
    }
    return inner.putMeta(meta, expectedRev: expectedRev);
  }

  @override
  Future<void> putTombstone(BookMeta tombstoned, {required int expectedRev}) =>
      inner.putTombstone(tombstoned, expectedRev: expectedRev);

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) async* {
    downloadStartBytes.add(startByte);
    final source = inner.downloadBook(bookId, startByte: startByte);
    final limit = failDownloadAfterBytes;
    if (limit == null) {
      yield* source;
      return;
    }
    // 一次性注入：发出 limit 字节后模拟断网，随后恢复普通行为。
    failDownloadAfterBytes = null;
    var sent = 0;
    await for (final chunk in source) {
      final remain = limit - sent;
      if (chunk.length <= remain) {
        sent += chunk.length;
        yield chunk;
      } else {
        yield chunk.sublist(0, remain);
        throw const BackendRequestException('下载中断（网络断开）');
      }
    }
  }

  @override
  Future<void> uploadBook(String bookId, File file, String contentHash) async {
    uploadAttempts++;
    if (uploadFailures.isNotEmpty) {
      throw uploadFailures.removeAt(0)();
    }
    return inner.uploadBook(bookId, file, contentHash);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

/// putMeta 恒冲突的包装（"再冲突 → ConflictUnresolvable"测试用）。
class AlwaysConflictAdapter implements BackendAdapter {
  AlwaysConflictAdapter(this.inner);

  final InMemoryAdapter inner;
  int putMetaAttempts = 0;

  @override
  BackendKind get kind => inner.kind;

  @override
  Future<void> connect(BackendConfig cfg) => inner.connect(cfg);

  @override
  Future<BackendCapabilities> probeCapabilities() => inner.probeCapabilities();

  @override
  Future<void> ensureLayout() => inner.ensureLayout();

  @override
  Future<String?> readLibraryJson() => inner.readLibraryJson();

  @override
  Future<void> deleteMeta(String bookId) => inner.deleteMeta(bookId);

  @override
  Future<MetaListing> listMetas({String? cursor}) =>
      inner.listMetas(cursor: cursor);

  @override
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch}) =>
      inner.getMeta(bookId, ifNoneMatch: ifNoneMatch);

  @override
  Future<void> putMeta(BookMeta meta, {required int expectedRev}) async {
    putMetaAttempts++;
    // 模拟他端持续并发写入：服务端总是比 expectedRev 新。
    final remoteRev = expectedRev + 1;
    throw RevConflict(
      meta.bookId,
      remoteRev,
      buildMeta(bookId: meta.bookId, rev: remoteRev),
    );
  }

  @override
  Future<void> putTombstone(
    BookMeta tombstoned, {
    required int expectedRev,
  }) async {
    throw RevConflict(tombstoned.bookId, expectedRev + 1, null);
  }

  @override
  Stream<List<int>> downloadBook(String bookId, {int? startByte}) =>
      inner.downloadBook(bookId, startByte: startByte);

  @override
  Future<void> uploadBook(String bookId, File file, String contentHash) =>
      inner.uploadBook(bookId, file, contentHash);

  @override
  Future<void> dispose() => inner.dispose();
}
