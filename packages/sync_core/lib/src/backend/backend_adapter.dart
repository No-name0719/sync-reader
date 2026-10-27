import 'dart:io';

import '../model/book_meta.dart';

/// 同步后端种类（docs/03 §4.3）。同一时刻只启用一个（FR-405）。
enum BackendKind { webdav, server }

/// 远端元数据摘要：清单阶段的轻量条目（不拉正文）。
class RemoteMetaStub {
  const RemoteMetaStub({
    required this.bookId,
    required this.rev,
    this.etag,
    this.size,
    this.modifiedAt,
    this.deleted = false,
  });

  final String bookId;
  final int rev;
  final String? etag; // WebDAV 条件请求用
  final int? size; // meta 文件字节数
  final DateTime? modifiedAt;
  final bool deleted; // tombstone
}

/// 元数据清单结果。REST 模式可携带服务端游标供增量续拉。
class MetaListing {
  const MetaListing({required this.stubs, this.cursor, this.hasMore = false});

  /// bookId → 摘要。
  final Map<String, RemoteMetaStub> stubs;

  /// REST 模式的增量游标（服务端全局 seq）；WebDAV 模式为 null。
  final String? cursor;
  final bool hasMore;
}

/// 后端连接配置。凭据（应用密码/token）由上层从安全存储读出后传入，
/// 本包不得将其写入任何持久化介质（NFR-03）。
class BackendConfig {
  const BackendConfig({
    required this.kind,
    required this.baseUrl,
    this.username,
    this.password,
    this.token,
    this.rootPath,
  });

  final BackendKind kind;

  /// WebDAV：`https://dav.jianguoyun.com/dav/`；REST：`http://host:port`。
  final String baseUrl;
  final String? username; // WebDAV 账号
  final String? password; // WebDAV 应用密码（只进安全存储）
  final String? token; // REST accessToken
  final String? rootPath; // 同步根目录；坚果云默认 /Apps/SyncReader
}

/// 两种后端（WebDAV 网盘 / 自建 REST 服务器）的统一抽象（docs/03 §4.3）。
///
/// 实现约束：
/// - 适配器只做传输，同步逻辑全部在 sync_core（CLAUDE.md §4.4）；
/// - `sync/test/contract/` 的同一套契约用例必须同时跑通两个实现（NFR-08）；
/// - 所有写操作幂等可重放（docs/04 §1.3）。
abstract interface class BackendAdapter {
  BackendKind get kind;

  /// 建立连接并做连通性/权限测试（读写 + 列目录 + MOVE 四项，FR-505）。
  Future<void> connect(BackendConfig cfg);

  /// 首次连接：幂等创建 `library.json / meta/ / books/ / tmp/`（docs/05 §1）。
  Future<void> ensureLayout();

  /// 元数据清单：WebDAV = PROPFIND Depth:1 on meta/；REST = GET /sync/changes?cursor。
  Future<MetaListing> listMetas({String? cursor});

  /// 单本 meta；`ifNoneMatch` 命中（未变更）时返回 null 并置 [MetaNotChanged] 语义
  /// ——简化为返回 null，调用方依据自身 etag 判断（docs/04 §4 阶段 3）。
  Future<BookMeta?> getMeta(String bookId, {String? ifNoneMatch});

  /// 写 meta。REST：PUT 带 `If-Match: "rev:{n}"` CAS，服务端 409 抛 [RevConflict]；
  /// WebDAV：先读后写，发现 rev 落后同样抛 [RevConflict]（语义一致的关键）。
  Future<void> putMeta(BookMeta meta, {required int expectedRev});

  /// 上传 tombstone（`deleted=true` 的 meta PUT），语义同 [putMeta]。
  Future<void> putTombstone(BookMeta tombstoned, {required int expectedRev});

  /// 下载正文，支持 Range 续传（`startByte`）；返回原始字节流。
  Stream<List<int>> downloadBook(String bookId, {int? startByte});

  /// 上传正文：`tmp/{bookId}.{ext}.part` → MOVE 原子提交；
  /// 幂等：远端已有相同 contentHash 的文件时跳过（docs/04 §5.3）。
  Future<void> uploadBook(String bookId, File file, String contentHash);

  Future<void> dispose();
}

/// 乐观锁冲突：服务端 rev 与 expectedRev 不符（HTTP 409 或 WebDAV 写前重读发现落后）。
/// 调用方取远端当前 meta → ConflictResolver 合并 → 以新 expectedRev 重试一次（docs/06 §2.2）。
class RevConflict implements Exception {
  RevConflict(this.bookId, this.remoteRev, this.remoteMeta);

  final String bookId;
  final int remoteRev;

  /// 服务端当前副本（409 body），供客户端合并。
  final BookMeta? remoteMeta;

  @override
  String toString() => 'RevConflict($bookId, remoteRev=$remoteRev)';
}

/// 连接/认证失败（WebDAV 401、REST token 失效）——触发重新授权流程。
class AuthFailed implements Exception {
  AuthFailed(this.message);

  final String message;

  @override
  String toString() => 'AuthFailed: $message';
}
