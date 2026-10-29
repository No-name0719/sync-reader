/// 本地存储占用统计与临时缓存清理（docs/10 §4.7 设置页「存储」区）。
///
/// 纯 `dart:io` 遍历，不依赖 provider，便于单测（真实临时目录）。
/// 所有遍历对单文件异常容错：跳过读不到的实体，绝不抛出中断统计。
library;

import 'dart:io';

import '../../data/files/book_file_store.dart';

/// 三目录占用统计（字节）。
class StorageUsage {
  const StorageUsage({
    required this.booksBytes,
    required this.coversBytes,
    required this.tmpBytes,
  });

  /// 统计 [store] 的 books / covers / tmp 三个目录。
  static Future<StorageUsage> of(BookFileStore store) async {
    return StorageUsage(
      booksBytes: await directorySize(store.booksDir),
      coversBytes: await directorySize(store.coversDir),
      tmpBytes: await directorySize(store.tmpDir),
    );
  }

  /// 正文目录（books/）占用。
  final int booksBytes;

  /// 封面目录（covers/）占用。
  final int coversBytes;

  /// 临时缓存目录（tmp/）占用。
  final int tmpBytes;

  /// 三目录合计。
  int get totalBytes => booksBytes + coversBytes + tmpBytes;
}

/// 递归计算目录总字节数；目录不存在返回 0，单文件读取失败跳过。
Future<int> directorySize(Directory dir) async {
  if (!dir.existsSync()) return 0;
  var total = 0;
  Stream<FileSystemEntity> entries;
  try {
    entries = dir.list(recursive: true, followLinks: false);
    await for (final entity in entries) {
      try {
        if (entity is File) total += await entity.length();
      } on FileSystemException {
        // 单个文件读不到（占用/权限）：跳过，不影响整体统计。
      }
    }
  } on FileSystemException {
    // 目录本身不可读：按 0 处理。
  }
  return total;
}

/// 清空目录内容（保留目录本身），返回删除的条目数。
///
/// 用于 tmp 缓存清理；正在被占用的文件删除失败时跳过，不中断。
Future<int> clearDirectoryContents(Directory dir) async {
  if (!dir.existsSync()) return 0;
  var removed = 0;
  for (final entity in dir.listSync()) {
    try {
      await entity.delete(recursive: entity is Directory);
      removed++;
    } on FileSystemException {
      // 占用中/权限不足：跳过。
    }
  }
  return removed;
}
