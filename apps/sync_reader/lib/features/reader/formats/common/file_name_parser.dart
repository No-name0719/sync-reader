/// 文件名元数据解析：`书名 - 作者.ext` 模式（FR-102）。
///
/// 规则：
/// - 去扩展名后切分：ASCII 短横线 `-` 必须两侧留白（避免误切连字号词）；
///   全角/长破折号 `–` `—` 允许不留白；
/// - 无分隔符 → 书名 = 全名，作者 = 空串；
/// - 多个分隔符 → 首个切分：书名 = 第一段，作者 = 其余合并。
library;

/// 文件名解析结果。
class FileNameMetadata {
  const FileNameMetadata({required this.title, required this.author});

  /// 书名（trim 过，非空——至少是原文件名主干）。
  final String title;

  /// 作者（trim 过，可为空串）。
  final String author;
}

/// `书名 - 作者` 的分隔符模式（首个命中即切分）。
/// 分支一：ASCII `-` 需两侧空白；分支二：`–`/`—` 允许无空白。
final _separatorPattern = RegExp(r'^(.+?)(?:\s+-\s+|\s*[–—]\s*)(.+)$');

/// 解析原始文件名（含扩展名）为 书名/作者。
FileNameMetadata parseBookFileName(String fileName) {
  var stem = fileName;
  final dot = stem.lastIndexOf('.');
  if (dot > 0) stem = stem.substring(0, dot); // '.隐藏文件' 这类保持原名
  stem = stem.trim();
  if (stem.isEmpty) return const FileNameMetadata(title: '', author: '');

  final match = _separatorPattern.firstMatch(stem);
  if (match == null) {
    return FileNameMetadata(title: stem, author: '');
  }
  final author = match.group(2)!.trim();
  return FileNameMetadata(title: match.group(1)!.trim(), author: author);
}
