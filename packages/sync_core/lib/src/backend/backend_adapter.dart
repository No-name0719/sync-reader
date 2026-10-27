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

  /// 清单阶段即可确知的 tombstone 标记。
  ///
  /// REST 后端由服务端直报；WebDAV 的 PROPFIND 看不到 JSON 内容里的删除
  /// 标记，恒为 false——tombstone 的权威判定在 [BackendAdapter.getMeta]
  /// 内容，引擎以拉取阶段 + 本地账本兜底（docs/04 §7.3），两种后端收敛语义一致。
  final bool deleted;
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

/// 云端正文文件条目（docs/04 §7.1 规则 4 云端孤儿清理的清单项）。
///
/// [name] 形如 `{bookId}.{ext}`（`books/` 下的实际文件名）；
/// [sizeBytes] 为文件字节数（诊断/流量预估用）。
class CloudBookFile {
  const CloudBookFile({required this.name, required this.sizeBytes});

  /// `books/` 下的文件名（不含目录前缀）。
  final String name;

  /// 文件字节数。
  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      other is CloudBookFile &&
      other.name == name &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(name, sizeBytes);

  @override
  String toString() => 'CloudBookFile($name, $sizeBytes)';
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

  /// 连接后能力探测（MOVE / ETag / Range，docs/04 §8.1）。
  /// 适配器内部可据此启用回退路径（如 size+mtime 合成 etag）。
  Future<BackendCapabilities> probeCapabilities();

  /// 首次连接：幂等创建 `library.json / meta/ / books/ / tmp/`（docs/05 §1）。
  Future<void> ensureLayout();

  /// 读取 `library.json` 原文；不存在返回 null（docs/05 §1）。
  /// 自建模式的后端键 `server:{libraryId}` 依赖本方法发现 libraryId。
  Future<String?> readLibraryJson();

  /// 删除云端 meta 文件（docs/04 §7.3）——仅供 90 天 tombstone GC 调用，
  /// 常规删除走 [putTombstone]，绝不删除 `books/` 下的正文。
  Future<void> deleteMeta(String bookId);

  /// 元数据清单：WebDAV = PROPFIND Depth:1 on meta/；REST = GET /sync/changes?cursor。
  Future<MetaListing> listMetas({String? cursor});

  /// 列 `books/` 下的正文文件（docs/04 §7.1 规则 4 云端孤儿清理）。
  /// 只列文件不列集合；目录缺失（首次同步前）返回空表。
  Future<List<CloudBookFile>> listBookFiles();

  /// 删除云端正文文件 `books/{name}`（docs/04 §7.1 规则 4：仅限用户逐文件
  /// 确认的孤儿清理入口，绝不自动调用）；404 视为幂等成功。
  Future<void> deleteBookFile(String name);

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
  ///
  /// [overwrite]（FR-410 文件替换，docs/05 §6 不变式 3 的显式出口）：
  /// - `false`（默认）：远端已存在**不同**内容 → [ContentHashMismatch]
  ///   （同 hash 仍幂等跳过）；
  /// - `true`：跳过"远端已有不同版本"检查，直接覆盖远端文件
  ///   （仍校验本地实际哈希与声明一致；仅供 FR-410 显式替换流程使用）。
  Future<void> uploadBook(
    String bookId,
    File file,
    String contentHash, {
    bool overwrite = false,
  });

  Future<void> dispose();
}

/// 乐观锁冲突：服务端 rev 与 expectedRev 不符（HTTP 409 或 WebDAV 写前重读发现落后）。
/// 调用方取远端当前 meta → ConflictResolver 合并 → 以新 expectedRev 重试一次（docs/06 §2.2）。
class RevConflict implements Exception {
  const RevConflict(this.bookId, this.remoteRev, this.remoteMeta);

  final String bookId;
  final int remoteRev;

  /// 服务端当前副本（409 body），供客户端合并。
  final BookMeta? remoteMeta;

  @override
  String toString() => 'RevConflict($bookId, remoteRev=$remoteRev)';
}

/// 连接/认证失败（WebDAV 401、REST token 失效）——触发重新授权流程。
class AuthFailed implements Exception {
  const AuthFailed(this.message);

  final String message;

  @override
  String toString() => 'AuthFailed: $message';
}

/// 连接后能力探测结果（docs/03 §4.3 / docs/04 §8.1）。
///
/// 由适配器在 [BackendAdapter.connect] 之后自检上报；无 ETag 的网盘以
/// `size + mtime` 合成 etag 属适配器内部实现，对引擎透明。
class BackendCapabilities {
  const BackendCapabilities({
    required this.supportsMove,
    required this.supportsEtag,
    required this.supportsRange,
  });

  /// 服务端是否支持 MOVE 原子提交（不支持的网盘以 Content-Length 校验兜底）。
  final bool supportsMove;

  /// 是否支持 ETag / If-None-Match 条件请求（304 语义）。
  final bool supportsEtag;

  /// 是否支持 Range 断点续传。
  final bool supportsRange;

  @override
  String toString() =>
      'BackendCapabilities(move=$supportsMove, etag=$supportsEtag, '
      'range=$supportsRange)';
}

/// 传输层异常：适配器抛出的可重试 HTTP/网络错误（docs/04 §8.4）。
///
/// 语义约定（错误映射的边界）：
/// - 401 → [AuthFailed]（认证类，不重试）；
/// - 409 / 412 / 428 → [RevConflict]（由引擎走合并流程，不进重试队列）；
/// - 429 / 5xx / 网络异常 → 本类（可重试，[TransferQueue] 负责退避）。
///
/// 引擎与传输队列只依赖本类，不直接依赖任何 HTTP 客户端。
class BackendRequestException implements Exception {
  const BackendRequestException(
    this.message, {
    this.statusCode,
    this.retryAfter,
    this.cause,
  });

  /// 开发者可读描述（不得含凭据）。
  final String message;

  /// HTTP 状态码；纯网络异常（连接失败/超时）为 null。
  final int? statusCode;

  /// 服务端 `Retry-After` 解析结果（429/503 优先尊重）。
  final Duration? retryAfter;

  /// 底层原始异常。
  final Object? cause;

  @override
  String toString() =>
      'BackendRequestException(${statusCode ?? 'network'}): $message';
}

/// 正文内容哈希不符（docs/04 §5.3 / 契约用例 6）：
/// 远端已存在不同版本的正文，或本地文件实际哈希与声明值不一致。
class ContentHashMismatch implements Exception {
  const ContentHashMismatch(this.bookId, this.message, {this.cause});

  final String bookId;
  final String message;
  final Object? cause;

  @override
  String toString() => 'ContentHashMismatch($bookId): $message';
}
