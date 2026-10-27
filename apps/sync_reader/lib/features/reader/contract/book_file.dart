/// 阅读器侧的书籍文件抽象：契约层与实现层之间传递文件信息的载体。
///
/// 有意与 drift 的 `Book` 行解耦：handler 只关心"文件在哪、叫什么、多大"，
/// 不感知数据库结构（docs/03 §4.2）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 打开中的书籍文件。
class BookFile {
  /// [path] 必须是绝对路径；[fileName] 是用户可见的原始文件名（含扩展名）。
  const BookFile({
    required this.path,
    required this.fileName,
    required this.sizeBytes,
  });

  /// 正文绝对路径。
  final String path;

  /// 原始文件名（导入时的名字，恢复导出用）。
  final String fileName;

  /// 正文字节数。
  final int sizeBytes;

  /// 小写扩展名（不含点），如 `txt` / `epub`。
  String get ext => p.extension(fileName).replaceFirst('.', '').toLowerCase();

  /// 对应的 Dart 文件对象（实现层读取用）。
  File get file => File(path);

  /// 从磁盘路径构造（读取文件大小）。
  static Future<BookFile> fromPath(String path) async {
    final f = File(path);
    final stat = await f.stat();
    return BookFile(
      path: path,
      fileName: p.basename(path),
      sizeBytes: stat.size,
    );
  }
}
