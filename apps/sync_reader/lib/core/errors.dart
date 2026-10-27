/// 通用错误类型，对齐 docs/03 §6.1 的 SyncError 六类分层。
///
/// M1 仅定义类型（供各层抛出/捕获的统一词汇表）；M2 同步引擎接入后，
/// UI 层只按 [SyncError.userMessage] 展示分类文案，不暴露堆栈（FR-406）。
library;

/// 同步/基础设施错误基类（sealed：分类固定，穷举 switch 安全）。
sealed class SyncError implements Exception {
  SyncError(this.message, {this.cause, this.stackTrace});

  /// 开发者可读的详细描述（中文，可含上下文；输出前仍需日志脱敏）。
  final String message;

  /// 原始异常（可空）。
  final Object? cause;

  /// 原始堆栈。
  final StackTrace? stackTrace;

  /// 面向用户的分类文案（UI 只展示该文案，FR-406）。
  String get userMessage;

  @override
  String toString() => '$runtimeType: $message';
}

/// 网络不可达 / 连接失败。
final class NetworkUnreachable extends SyncError {
  NetworkUnreachable(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => '网络不可用，请检查网络连接后重试';
}

/// 认证失败（WebDAV 401 / REST token 失效等）。
final class AuthFailed extends SyncError {
  AuthFailed(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => '登录凭据无效或已过期，请重新配置账号';
}

/// 配额超限（坚果云流量超限等，docs/04 §8.3）。
final class QuotaExceeded extends SyncError {
  QuotaExceeded(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => '同步流量已达本月上限，同步已暂停';
}

/// 冲突无法自动合并（docs/04 §6 的兜底分支）。
final class ConflictUnresolvable extends SyncError {
  ConflictUnresolvable(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => '同步冲突无法自动解决，请手动选择保留版本';
}

/// 服务端错误（REST 5xx 等）。
final class ServerError extends SyncError {
  ServerError(super.message, {this.statusCode, super.cause, super.stackTrace});

  /// HTTP 状态码（可空，非 HTTP 场景无值）。
  final int? statusCode;

  @override
  String get userMessage => '服务器出错，请稍后重试';
}

/// 数据损坏（meta 校验失败 / 正文哈希不一致等，docs/05 §6）。
final class Corruption extends SyncError {
  Corruption(super.message, {super.cause, super.stackTrace});

  @override
  String get userMessage => '数据损坏，该书已跳过同步，可尝试删除后重新导入';
}
