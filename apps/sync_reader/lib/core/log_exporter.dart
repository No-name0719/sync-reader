/// 诊断日志导出器（FR-604）。
///
/// 把 [AppLogger] 静态环形缓冲导出为 UTF-8 文本文件，导出前做
/// **二次脱敏核查**（[LogExporter.sanitizeAgain]）——这是一级脱敏
/// [AppLogger.redactCredentials] 之上的独立防线，规则取"宁枉勿纵"：
/// 疑似凭据/密钥/哈希的形态一律打码，宁可导出件缺信息，不可泄漏。
library;

import 'dart:convert';
import 'dart:io';

// package_info_plus 在依赖树中（pubspec.lock 传递依赖），任务契约允许直接使用；
// pubspec.yaml 冻结不可改，故无法把它提升为直接依赖，suppress 该 lint。
// ignore: depend_on_referenced_packages
import 'package:package_info_plus/package_info_plus.dart';

import 'app_logger.dart';

/// 组装完成的导出内容：全文（头部 + 脱敏正文）与日志行数。
class LogExportContent {
  const LogExportContent({required this.content, required this.lineCount});

  /// 完整文件内容（UTF-8 文本）。
  final String content;

  /// 正文日志行数（不含头部）。
  final int lineCount;
}

/// 日志导出：组装 + 二次脱敏 + 落盘。
final class LogExporter {
  LogExporter._();

  /// 版本信息提供者：默认 [PackageInfo.fromPlatform]；
  /// 测试注入假实现以避免平台通道（MissingPluginException）。
  static Future<PackageInfo> Function() packageInfoProvider =
      PackageInfo.fromPlatform;

  /// 邮箱（坚果云账号即邮箱，日志中可能以 `account=` 或纯文本出现）。
  static final RegExp _emailPattern = RegExp(
    r'([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)',
  );

  /// URL 内嵌凭据：`scheme://user:pass@host`。
  static final RegExp _urlCredentialPattern = RegExp(
    r'([A-Za-z][A-Za-z0-9+.-]*://)([^\s/:@]+):([^\s/@]+)@',
  );

  /// 40 位以上十六进制连续串（疑似密钥/哈希）。
  static final RegExp _longHexPattern = RegExp(r'\b[0-9a-fA-F]{40,}\b');

  /// 32 位以上 base64url 连续串（疑似密钥/令牌）。
  static final RegExp _longBase64UrlPattern = RegExp(
    r'(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{32,}(?![A-Za-z0-9_-])',
  );

  /// 二次脱敏核查：对"已过一级 [AppLogger.redactCredentials]"的日志行
  /// 再做一遍独立防线（FR-604），规则冻结如下：
  ///
  /// 1. Bearer/Basic 后随串 → `***`（一级已覆盖，此处兜底漏网形态）；
  /// 2. URL 内嵌凭据 `scheme://user:pass@host` → `scheme://***@host`
  ///    （先于邮箱执行，防 `pass@host` 段被误当邮箱提前改写）；
  /// 3. 邮箱 → 掩码本地部分保留域名（如 `abc***@example.com`）；
  /// 4. 40 位以上十六进制 → `***`（疑似密钥/哈希泄漏）。
  ///    取舍说明：`sha256:<64hex>` 内容哈希属书库元数据、并非机密，
  ///    但哈希可从本地正文重算，导出件宁可不带，故为简单一致也一并打码；
  /// 5. 32 位以上 base64url 连续串 → `***`（宁枉勿纵）。
  ///
  /// 普通中文/短标识符（bookId、ULID 26 位、tfp 指纹等）不受影响。
  static String sanitizeAgain(String line) {
    var out = line;
    // 1) Bearer/Basic 兜底（大小写不敏感）。
    out = out.replaceAllMapped(
      RegExp(r'(bearer|basic)(\s+)(\S+)', caseSensitive: false),
      (m) => '${m[1]}${m[2]}***',
    );
    // 2) URL 内嵌凭据（注意须先于邮箱规则，见上）。
    out = out.replaceAllMapped(_urlCredentialPattern, (m) => '${m[1]}***@');
    // 3) 邮箱：本地部分保留前 3 位（不足 3 位全保留）+ ***，域名不动。
    out = out.replaceAllMapped(_emailPattern, (m) {
      final local = m[1]!;
      final keep = local.length <= 3 ? local : local.substring(0, 3);
      return '$keep***@${m[2]}';
    });
    // 4) 长 hex → ***（含 sha256:<64hex> 内容哈希，见上取舍说明）。
    out = out.replaceAllMapped(_longHexPattern, (_) => '***');
    // 5) 长 base64url → ***。
    out = out.replaceAllMapped(_longBase64UrlPattern, (_) => '***');
    return out;
  }

  /// 组装导出内容（不落盘）：
  /// 头部 = 应用版本（version+buildNumber）+ 平台 + 导出时间 + 行数；
  /// 正文 = 环形缓冲逐行 [sanitizeAgain]。
  static Future<LogExportContent> buildContent() async {
    final info = await packageInfoProvider();
    final lines = AppLogger.snapshot().map(sanitizeAgain).toList();
    final header = StringBuffer()
      ..writeln('SyncReader 诊断日志（FR-604）')
      ..writeln('应用版本：${info.version}+${info.buildNumber}')
      ..writeln('平台：${Platform.operatingSystem}')
      ..writeln('导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('日志行数：${lines.length}')
      ..writeln('-' * 40);
    final body = lines.isEmpty ? '' : '${lines.join('\n')}\n';
    return LogExportContent(content: '$header$body', lineCount: lines.length);
  }

  /// 导出到指定路径（冻结契约入口，供拿到具体路径的调用方/测试使用）。
  ///
  /// [savePath] 为 null 表示用户取消，静默返回 null；
  /// 成功返回写入的日志行数；写盘失败向上抛异常由调用方展示。
  static Future<int?> exportTo(String? savePath) async {
    if (savePath == null) return null;
    final bundle = await buildContent();
    await File(savePath)
        .writeAsString(bundle.content, encoding: utf8, flush: true);
    return bundle.lineCount;
  }
}
