/// 书籍/封面文件存取（docs/03 §2 data/files）。
///
/// 目录布局（应用支持目录下）：
/// ```
/// files/
/// ├── books/{bookId}/source.{ext}   # 正文
/// ├── covers/{bookId}.png           # 封面
/// ├── orphans/                      # 游离文件（书目丢失的正文，用户可恢复/清理）
/// └── tmp/                          # 下载/上传暂存（M2）
/// ```
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/app_logger.dart';

/// 文件存储布局管理器。所有路径解析集中于此，禁止在别处手拼路径。
final class BookFileStore {
  /// 以 `files` 根目录构造（通常是 `{应用支持目录}/files`）。
  BookFileStore(this.root);

  /// files 根目录。
  final Directory root;

  static final _log = AppLogger();

  Directory get booksDir => Directory(p.join(root.path, 'books'));
  Directory get coversDir => Directory(p.join(root.path, 'covers'));
  Directory get orphansDir => Directory(p.join(root.path, 'orphans'));
  Directory get tmpDir => Directory(p.join(root.path, 'tmp'));

  /// 首次启动建目录（幂等）。
  Future<void> ensureLayout() async {
    for (final dir in [booksDir, coversDir, orphansDir, tmpDir]) {
      await dir.create(recursive: true);
    }
  }

  /// 正文路径：`books/{bookId}/source.{ext}`。
  String resolveBookPath(String bookId, String ext) => p.join(
    booksDir.path,
    bookId,
    'source.${ext.toLowerCase().replaceAll('.', '')}',
  );

  /// 封面路径：`covers/{bookId}.png`。
  String resolveCoverPath(String bookId) =>
      p.join(coversDir.path, '$bookId.png');

  /// 导入时把源文件复制入 books 目录（原文件保留在用户处，FR-101）。
  ///
  /// 返回落库用的本地路径（[resolveBookPath] 同一位置）。
  Future<String> importCopy({
    required String bookId,
    required String ext,
    required File source,
  }) async {
    final targetPath = resolveBookPath(bookId, ext);
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    await source.copy(targetPath);
    _log.info('导入正文：bookId=$bookId size=${await source.length()}');
    return targetPath;
  }

  /// 把整本书的正文目录移入游离区（或phans/{bookId}-{时间戳}/）。
  ///
  /// 用于"书目记录已消失但文件还在"的自检场景（docs/03 §6.4）。
  /// 返回游离目录路径；书目录不存在时返回 null。
  Future<String?> moveToOrphans(String bookId) async {
    final bookDir = Directory(p.join(booksDir.path, bookId));
    if (!bookDir.existsSync()) return null;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = p.join(orphansDir.path, '$bookId-$stamp');
    await bookDir.rename(target);
    _log.warn('正文移入游离区：bookId=$bookId');
    return target;
  }

  /// 列出游离文件（"游离文件"面板用，docs/03 §6.4）。
  Future<List<FileSystemEntity>> listOrphans() async {
    if (!orphansDir.existsSync()) return const [];
    return orphansDir.list().toList();
  }

  /// 删除整本书的本地文件：正文目录 + 封面。
  ///
  /// 注意：这是显式的用户删除动作；同步语义层"永不自动删正文"由调用方把握。
  Future<void> deleteBookFiles(String bookId) async {
    final bookDir = Directory(p.join(booksDir.path, bookId));
    if (bookDir.existsSync()) {
      await bookDir.delete(recursive: true);
    }
    final cover = File(resolveCoverPath(bookId));
    if (cover.existsSync()) {
      await cover.delete();
    }
    _log.info('删除本地文件：bookId=$bookId');
  }

  // ── 平铺正文（游离文件面板，FR-408 / docs/04 §7.1.3）───────────────────

  /// 平铺正文路径：`books/{bookId}.{ext}`。
  ///
  /// 与云端 `books/{bookId}.{ext}` 同形的平铺布局，游离文件面板的扫描
  /// 差集与挂回目标都按此路径约定（游离文件 = 文件名主干 ∉ books.bookId
  /// 集合的平铺正文）。
  String resolveFlatBookPath(String bookId, String ext) =>
      p.join(booksDir.path, '$bookId.${ext.toLowerCase().replaceAll('.', '')}');

  /// 游离正文挂回书库：同盘 rename 进平铺路径（原路径不复存在，零拷贝）。
  ///
  /// [bookId] 为新生成的 ULID；目标已存在视为异常（新 ULID 正常不会撞）。
  /// 返回挂回后的正文路径（登记 books.localPath 用）。
  Future<String> adoptBookFile({
    required String bookId,
    required String ext,
    required File source,
  }) async {
    final targetPath = resolveFlatBookPath(bookId, ext);
    final target = File(targetPath);
    if (target.existsSync()) {
      throw StateError('挂回目标路径已存在：$targetPath');
    }
    await target.parent.create(recursive: true);
    await source.rename(targetPath);
    _log.info('游离正文挂回：bookId=$bookId size=${await target.length()}');
    return targetPath;
  }
}
