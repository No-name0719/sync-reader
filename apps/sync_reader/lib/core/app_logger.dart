/// 简单分级日志器（docs/03 §6.3）。
///
/// - debugPrint 实现，info / warn / error 三级；
/// - 所有输出先经过脱敏钩子（[sanitize]），默认实现 [redactCredentials]
///   会将 password / token / secret / authorization 等凭据字段打码，
///   满足 NFR-03"凭据禁止写入日志"。
/// - M2 接入同步引擎后如需结构化日志/落盘，可在保持接口不变的前提下替换实现。
library;

import 'package:flutter/foundation.dart';

/// 消息脱敏钩子：输入原始消息，返回可安全输出的消息。
typedef LogSanitizer = String Function(String message);

/// 日志级别。
enum LogLevel { info, warn, error }

/// 应用日志器。
final class AppLogger {
  /// 创建日志器。
  ///
  /// [sanitizer]：消息脱敏钩子，默认 [redactCredentials]；
  /// [minLevel]：低于该级别的日志直接丢弃（error > warn > info）。
  AppLogger({
    LogSanitizer? sanitizer,
    this.minLevel = LogLevel.info,
    this.enabled = kDebugMode,
  }) : sanitize = sanitizer ?? redactCredentials;

  /// 低于该级别的日志不输出。
  final LogLevel minLevel;

  /// 是否输出（release 构建默认关闭，避免性能损耗）。
  final bool enabled;

  /// 消息脱敏钩子。
  final LogSanitizer sanitize;

  /// 普通信息。
  void info(String message) => _log(LogLevel.info, message);

  /// 警告（不影响主流程的异常，如解析降级）。
  void warn(String message) => _log(LogLevel.warn, message);

  /// 错误（可附错误对象与堆栈）。
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    final buffer = StringBuffer(message);
    if (error != null) buffer.write(' | $error');
    if (stackTrace != null) buffer.write('\n$stackTrace');
    _log(LogLevel.error, buffer.toString());
  }

  void _log(LogLevel level, String rawMessage) {
    if (!enabled || level.index < minLevel.index) return;
    final now = DateTime.now().toIso8601String();
    debugPrint('[$now][${level.name.toUpperCase()}] ${sanitize(rawMessage)}');
  }

  /// 默认脱敏规则：对常见凭据键的值整体打码（含 `Bearer` 前缀）。
  ///
  /// 覆盖形态：`password=xxx`、`"token": "xxx"`、`Authorization: Bearer xxx` 等。
  static String redactCredentials(String message) {
    return message.replaceAllMapped(
      RegExp(
        r'(password|passwd|token|secret|authorization|credential)'
        r'(\s*[:=]\s*)(?:"([^"]*)"|((?:bearer\s+|basic\s+)?\S+))',
        caseSensitive: false,
      ),
      (m) => '${m[1]}${m[2]}***',
    );
  }
}
