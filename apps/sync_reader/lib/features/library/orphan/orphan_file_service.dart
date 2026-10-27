/// 游离文件服务（FR-408 游离文件面板）：只读扫描 + 彻底删除。
///
/// 语义冻结（docs/04 §7.1）：游离文件 = 正文文件仍在、但其 bookId 已不在
/// books 表。覆盖三种真实形态（见 [OrphanShape] 文档）：
/// - `orphans/` 游离区目录（本端删除经 moveToOrphans 移入，docs/04 §7.1.1）；
/// - `books/{bookId}/` 分层目录残留（他端 tombstone 后正文保留，§7.1.2）；
/// - `books/{bookId}.{ext}` 平铺残留。
/// 扫描全程无 DB 写入（只读）；非 handler 支持格式的文件不是正文 → 不进
/// 面板。删除是显式的用户确认动作（面板二次确认后调用）：删容器/文件并
/// 顺带清理 `covers/{stem}.png` 残留；deleted_books 账本不动（90 天 GC 自理）。
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/providers.dart';
import '../../../core/app_logger.dart';
import '../../../data/db/daos/books_dao.dart';
import '../../../data/files/book_file_store.dart';
import '../../reader/contract/format_registry.dart';
import 'orphan_book_file.dart';

/// 游离文件服务。依赖经构造注入，便于测试（内存库 + 临时目录 + 假 handler）。
class OrphanFileService {
  OrphanFileService({
    required this._booksDao,
    required this._registry,
    required this._fileStore,
  });

  final BooksDao _booksDao;
  final FormatRegistry _registry;
  final Future<BookFileStore> _fileStore;

  static final _log = AppLogger();

  /// 只读扫描游离文件（面板打开 / 操作后重扫调用）。
  ///
  /// 目录不存在（首次启动未建 / 被清理）返回空列表；无法访问的单个条目
  /// 静默跳过，不中断整次扫描。结果按展示名排序（稳定可测）。
  Future<List<OrphanBookFile>> scan() async {
    final store = await _fileStore;
    final bookIds = await _booksDao.readAllBookIds();
    final orphans = <OrphanBookFile>[];
    orphans.addAll(await _scanBooksDir(store, bookIds));
    orphans.addAll(await _scanOrphansArea(store, bookIds));
    orphans.sort((a, b) => a.fileName.compareTo(b.fileName));
    return orphans;
  }

  /// books/ 目录：平铺文件 + 分层目录两种形态。
  Future<List<OrphanBookFile>> _scanBooksDir(
    BookFileStore store,
    Set<String> bookIds,
  ) async {
    final dir = store.booksDir;
    if (!dir.existsSync()) return const [];
    final orphans = <OrphanBookFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is File) {
          final orphan = _flatOrphan(
            entity,
            stem: p.basenameWithoutExtension(entity.path),
            shape: OrphanShape.flat,
            bookIds: bookIds,
          );
          if (orphan != null) orphans.add(orphan);
        } else if (entity is Directory) {
          // 分层布局 books/{bookId}/source.{ext}：目录名即 bookId。
          final bookId = p.basename(entity.path);
          if (bookIds.contains(bookId)) continue;
          final content = await _contentFileInDir(entity);
          if (content == null) continue;
          orphans.add(
            OrphanBookFile(
              path: content.file.path,
              fileName: bookId,
              stem: bookId,
              ext: content.ext,
              sizeBytes: await content.file.length(),
              formatId: content.formatId,
              containerPath: entity.path,
              shape: OrphanShape.layeredResidue,
            ),
          );
        }
      } catch (_) {
        // 条目读取失败（读取中途消失 / 无权限）：静默跳过。
      }
    }
    return orphans;
  }

  /// orphans/ 游离区：`{bookId}-{时间戳}/` 整书目录（moveToOrphans 产物）；
  /// 兼容直接平铺在区内的文件（自检迁移的历史形态）。
  Future<List<OrphanBookFile>> _scanOrphansArea(
    BookFileStore store,
    Set<String> bookIds,
  ) async {
    final dir = store.orphansDir;
    if (!dir.existsSync()) return const [];
    final orphans = <OrphanBookFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is Directory) {
          // 目录名 `{bookId}-{毫秒时间戳}`：剥时间戳后缀还原 bookId。
          final dirname = p.basename(entity.path);
          final bookId = _stripStampSuffix(dirname);
          if (bookId == null || bookIds.contains(bookId)) continue;
          final content = await _contentFileInDir(entity);
          if (content == null) continue;
          orphans.add(
            OrphanBookFile(
              path: content.file.path,
              fileName: dirname,
              stem: bookId,
              ext: content.ext,
              sizeBytes: await content.file.length(),
              formatId: content.formatId,
              containerPath: entity.path,
              shape: OrphanShape.orphanArea,
            ),
          );
        } else if (entity is File) {
          final orphan = _flatOrphan(
            entity,
            stem: p.basenameWithoutExtension(entity.path),
            shape: OrphanShape.orphanArea,
            bookIds: bookIds,
          );
          if (orphan != null) orphans.add(orphan);
        }
      } catch (_) {
        // 静默跳过（同 books/ 目录）。
      }
    }
    return orphans;
  }

  /// 平铺文件 → 游离条目；非正文格式或主干已关联返回 null。
  OrphanBookFile? _flatOrphan(
    File entity, {
    required String stem,
    required OrphanShape shape,
    required Set<String> bookIds,
  }) {
    final name = p.basename(entity.path);
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    final handler = _registry.byExtension(ext);
    if (handler == null) return null;
    if (bookIds.contains(stem)) return null;
    return OrphanBookFile(
      path: entity.path,
      fileName: name,
      stem: stem,
      ext: ext,
      sizeBytes: entity.lengthSync(),
      formatId: handler.formatId,
      shape: shape,
    );
  }

  /// 目录内的正文文件：优先 `source.{ext}`（moveToOrphans/分层布局约定），
  /// 否则取首个 handler 支持格式的文件；无则返回 null（非正文目录）。
  Future<({File file, String ext, String formatId})?> _contentFileInDir(
    Directory dir,
  ) async {
    File? found;
    var ext = '';
    var formatId = '';
    await for (final entry in dir.list(followLinks: false)) {
      if (entry is! File) continue;
      final name = p.basename(entry.path);
      final candidateExt = p
          .extension(name)
          .replaceFirst('.', '')
          .toLowerCase();
      final handler = _registry.byExtension(candidateExt);
      if (handler == null) continue;
      if (p.basenameWithoutExtension(name) == 'source' ||
          p.basenameWithoutExtension(name) == 'book') {
        found = entry;
        ext = candidateExt;
        formatId = handler.formatId;
        break;
      }
      found ??= entry;
      if (ext.isEmpty) {
        ext = candidateExt;
        formatId = handler.formatId;
      }
    }
    if (found == null) return null;
    return (file: found, ext: ext, formatId: formatId);
  }

  /// 剥 `{bookId}-{毫秒时间戳}` 的时间戳后缀；非该形态返回 null。
  static String? _stripStampSuffix(String dirname) {
    final idx = dirname.lastIndexOf('-');
    if (idx <= 0 || idx == dirname.length - 1) return null;
    final suffix = dirname.substring(idx + 1);
    if (int.tryParse(suffix) == null) return null;
    return dirname.substring(0, idx);
  }

  /// 彻底删除单个游离条目（面板二次确认后调用）。
  ///
  /// 目录形态递归删容器；平铺删文件。并顺带清理 `covers/{stem}.png` 残留
  /// （如存在——书此前在库时可能已生成封面）。已不存在时幂等通过。
  Future<void> deleteOrphan(OrphanBookFile orphan) async {
    final container = orphan.containerPath;
    if (container != null) {
      final dir = Directory(container);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } else {
      final file = File(orphan.path);
      if (await file.exists()) {
        await file.delete();
      }
    }
    final store = await _fileStore;
    final cover = File(store.resolveCoverPath(orphan.stem));
    if (await cover.exists()) {
      await cover.delete();
    }
    _log.info('游离文件彻底删除：${orphan.fileName}');
  }

  /// 挂回成功后的容器清理（挂回已把正文 rename 出去，容器通常已空；
  /// 平铺形态无容器，直接返回）。失败静默——残留空目录下次删除时兜底。
  Future<void> cleanupContainer(OrphanBookFile orphan) async {
    final container = orphan.containerPath;
    if (container == null) return;
    try {
      final dir = Directory(container);
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      _log.warn('游离容器清理失败（忽略）：$container');
      _log.error('游离容器清理异常详情', e);
    }
  }
}

/// 游离文件服务 provider（app 作用域；测试容器级 override 注入假实现）。
final orphanFileServiceProvider = Provider<OrphanFileService>((ref) {
  return OrphanFileService(
    booksDao: ref.watch(booksDaoProvider),
    registry: ref.watch(formatRegistryProvider),
    fileStore: ref.watch(bookFileStoreProvider.future),
  );
});
