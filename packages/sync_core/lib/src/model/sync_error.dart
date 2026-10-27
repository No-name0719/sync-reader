import 'dart:async';
import 'dart:io';

import '../backend/backend_adapter.dart';

/// 同步错误统一分层（docs/03 §6.1）：sealed 六类，穷举 switch 安全。
///
/// UI 只按分类展示文案，不暴露堆栈（FR-406）。本类同时实现 [Exception]，
/// 允许底层（如 TransferQueue 重试耗尽后）直接抛出实例，由上层捕获展示。
///
/// 命名说明：认证类命名为 [AuthFailedSyncError] 而非 docs/03 §6.1 的
/// "AuthFailed"——传输层已有 [AuthFailed] 异常类占用该名字（docs/04 §8.4
/// 的 401 载体），同类导出会产生名字冲突。
sealed class SyncError implements Exception {
  const SyncError(this.message, [this.cause]);

  /// 开发者可读的详细描述（中文；输出前需日志脱敏）。
  final String message;

  /// 原始异常（可空）。
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// 网络不可达 / 连接失败（含重试耗尽）。
final class NetworkUnreachable extends SyncError {
  const NetworkUnreachable(super.message, [super.cause]);
}

/// 认证失败（WebDAV 401 / REST token 失效等）。
final class AuthFailedSyncError extends SyncError {
  const AuthFailedSyncError(super.message, [super.cause]);
}

/// 配额超限（坚果云流量超限等，docs/04 §8.3）。
final class QuotaExceeded extends SyncError {
  const QuotaExceeded(super.message, [super.cause]);
}

/// 冲突无法自动合并（合并后重试仍冲突的兜底分支，docs/04 §6.1）。
final class ConflictUnresolvable extends SyncError {
  const ConflictUnresolvable(super.message, [super.cause]);
}

/// 服务端错误（REST 5xx / 限流重试耗尽等）。
final class ServerError extends SyncError {
  const ServerError(super.message, [super.cause, this.statusCode]);

  /// HTTP 状态码（可空，非 HTTP 场景无值）。
  final int? statusCode;
}

/// 数据损坏（meta 校验失败 / 正文哈希不一致 / 云端正文缺失，docs/05 §6）。
final class Corruption extends SyncError {
  const Corruption(super.message, [super.cause]);
}

/// 传输层异常/任意异常 → [SyncError] 六类的统一映射入口。
///
/// UI 只见分类不见堆栈：映射后原始异常保留在 [SyncError.cause] 供日志脱敏输出。
abstract final class SyncErrorMapper {
  /// 把任意异常映射为六类之一；已是 [SyncError] 的原样返回。
  static SyncError fromException(Object error, {String? context}) {
    final prefix = context == null ? '' : '$context: ';
    if (error is SyncError) return error;
    if (error is AuthFailed) {
      return AuthFailedSyncError('$prefix认证失败，请重新配置账号', error);
    }
    if (error is RevConflict) {
      return ConflictUnresolvable('$prefix冲突合并失败', error);
    }
    if (error is BackendRequestException) {
      return _fromRequestException(error, prefix);
    }
    if (error is FormatException) {
      // meta JSON 严格校验失败 → 标记 Corruption 并跳过（docs/05 §6）。
      return Corruption('$prefix元数据校验失败', error);
    }
    if (error is SocketException) {
      return NetworkUnreachable('$prefix网络不可达', error);
    }
    if (error is TimeoutException) {
      return NetworkUnreachable('$prefix连接超时', error);
    }
    if (error is ContentHashMismatch) {
      return Corruption('$prefix正文哈希不一致', error);
    }
    return ServerError('$prefix未知同步错误', error);
  }

  static SyncError _fromRequestException(
    BackendRequestException error,
    String prefix,
  ) {
    final code = error.statusCode;
    if (code == 401) return AuthFailedSyncError('$prefix认证失效', error);
    if (code == 404) return Corruption('$prefix云端资源缺失', error);
    if (code != null && code >= 500 && code < 600) {
      return ServerError('$prefix服务端错误（HTTP $code）', error, code);
    }
    // 429 限流与纯网络异常归入可重试的网络类。
    return NetworkUnreachable(
      code == null ? '$prefix网络不可达' : '$prefix请求被限流（HTTP $code）',
      error,
    );
  }
}
