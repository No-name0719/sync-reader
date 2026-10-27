/// 内容哈希工具：流式 SHA-256（FR-102）。
///
/// 输出格式与 docs/05 §3.2 约定一致：`sha256:<hex>`。
/// 基于 crypto 包的 chunked 转换，按流分块读取文件，
/// 500MB 级文件计算时不将全文载入内存、不阻塞 UI（应在 isolate 外直接调用亦安全，
/// 读文件在 IO 线程分块进行；如后续需要更彻底的隔离可再包 isolate）。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

/// 正文全量哈希计算器。
final class ContentHasher {
  ContentHasher._();

  /// 计算文件的内容哈希（流式分块读取）。
  static Future<String> hashFile(File file) => hashStream(file.openRead());

  /// 计算字节流的内容哈希。
  static Future<String> hashStream(Stream<List<int>> chunks) async {
    final digest = await sha256.bind(chunks).first;
    return 'sha256:$digest';
  }
}
