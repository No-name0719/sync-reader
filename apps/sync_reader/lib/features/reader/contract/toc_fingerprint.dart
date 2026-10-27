/// 目录指纹算法（docs/05 §3.2 tocFingerprint）。
///
/// 指纹 = 对 toc 结构序列化后取 SHA-256 前 16 个 hex 字符。
/// 用途：跨端/跨版本目录解析结果不一致时（解析器升级、规则调整），
/// 进度定位从 locator 精确恢复降级为 percent，防跳错章节（docs/05 §3.3）。
library;

import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'toc_entry.dart';

/// 目录指纹计算器（纯函数，所有 handler 复用）。
final class TocFingerprint {
  TocFingerprint._();

  /// 序列化格式：每行 `level|title|anchor.toString()\n`。
  ///
  /// 依赖 [TocEntry.anchor] 的稳定 `toString()`——这是锚点类的硬性契约。
  static String compute(List<TocEntry> toc) {
    final buffer = StringBuffer();
    for (final entry in toc) {
      buffer
        ..write(entry.level)
        ..write('|')
        ..write(entry.title)
        ..write('|')
        ..writeln(entry.anchor.toString());
    }
    final hex = sha256.convert(utf8.encode(buffer.toString())).toString();
    return 'tfp:${hex.substring(0, 16)}';
  }
}
