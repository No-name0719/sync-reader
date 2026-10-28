/// 简单分级日志器（docs/03 §6.3；FR-604 起支持环形缓冲与导出）。
///
/// - debugPrint 实现，info / warn / error 三级；
/// - 所有输出先经过脱敏钩子（[sanitize]），默认实现 [redactCredentials]
///   会将 password / token / secret / authorization 等凭据字段打码，
///   满足 NFR-03"凭据禁止写入日志"；
/// - 全实例共享一份**静态环形缓冲**（默认 2000 行，超限淘汰最旧），
///   缓冲内容为与 debugPrint 一致的最终字符串（已脱敏 + 级别与时间戳前缀），
///   供 [AppLogger.snapshot] / LogExporter 导出诊断日志（FR-604）。
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
  /// [minLevel]：低于该级别的日志直接丢弃（error > warn > info）；
  /// [enabled]：是否记录（FR-604 起默认恒开——release 也必须落环形缓冲
  /// 以便线上导出排查；debugPrint 在 release 本就是 no-op，输出性能无损，
  /// 缓冲照常。仅测试静音时显式传 false）。
  AppLogger({
    LogSanitizer? sanitizer,
    this.minLevel = LogLevel.info,
    this.enabled = true,
  }) : sanitize = sanitizer ?? redactCredentials;

  /// 低于该级别的日志不输出。
  final LogLevel minLevel;

  /// 是否记录（默认恒 true，release 行为由该默认值保证）。
  final bool enabled;

  /// 消息脱敏钩子。
  final LogSanitizer sanitize;

  /// 环形缓冲默认容量（行数），超限淘汰最旧。
  static const int defaultBufferCapacity = 2000;

  /// 全实例共享的环形缓冲（FR-604）：存"已脱敏 + 带级别与时间戳前缀"的最终行。
  static final List<String> _buffer = <String>[];

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

  /// 环形缓冲快照：时间序的副本，改动副本不影响缓冲本身。
  static List<String> snapshot() => List.of(_buffer);

  /// 清空环形缓冲（设置页"清空日志"入口）。
  static void clear() => _buffer.clear();

  void _log(LogLevel level, String rawMessage) {
    if (!enabled || level.index < minLevel.index) return;
    final now = DateTime.now().toIso8601String();
    final line = '[$now][${level.name.toUpperCase()}] ${sanitize(rawMessage)}';
    debugPrint(line);
    // 脱敏之后追加进缓冲（warn / error 也进），供导出排查（FR-604）。
    _buffer.add(line);
    if (_buffer.length > defaultBufferCapacity) {
      _buffer.removeRange(0, _buffer.length - defaultBufferCapacity);
    }
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
