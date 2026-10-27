/// 封面生成与存量回填：云端书（占位书下载完成/修复前已下载的书）此前
/// 永远没有真实封面——封面提取原本只发生在本机导入时。
///
/// 职责（封面是 app 层职责，引擎不管封面）：
/// - [CoverGenerator.generateForBook]：对已落盘正文按格式提取封面字节
///   （复用 `FormatRegistry`/handler 的 `parseMetadata` 路径；epub 必须生效，
///   txt/md/pdf 无封面则跳过）→ 写 `covers/{bookId}.png` → 更新 books 行
///   coverPath → 书库经 drift watch 自动刷新；
/// - [CoverGenerator.backfillMissing]：对 `localPath != null && coverPath == null`
///   的存量书一次性批量补生成（失败静默逐书跳过，不重试到下次重启）。
///
/// 防重入：同一 bookId 并发只跑一次；已尝试过的 bookId（成功/失败/无封面）
/// 本进程内不再重复解析（parseMetadata 可能较耗时，epub 需解压）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/app_logger.dart';
import '../../../data/db/daos/books_dao.dart';
import '../../../data/files/book_file_store.dart';
import '../../reader/contract/book_file.dart';
import '../../reader/contract/format_registry.dart';

/// 把封面字节写入 `covers/{bookId}.png`，返回登记用的路径；空字节返回 null。
///
/// 本机导入（[BookImportService]）与下载后补生成共用本函数——文件名沿用
/// [BookFileStore.resolveCoverPath] 冻结的 `covers/{bookId}.png`（字节魔数
/// png/jpg 皆可由 flutter 解码器按内容识别）。
Future<String?> writeCoverFile(
  BookFileStore store,
  String bookId,
  Uint8List? bytes,
) async {
  if (bytes == null || bytes.isEmpty) return null;
  final coverPath = store.resolveCoverPath(bookId);
  final coverFile = File(coverPath);
  await coverFile.parent.create(recursive: true);
  await coverFile.writeAsBytes(bytes, flush: true);
  return coverPath;
}

/// 封面生成器（依赖注入便于测试）。
class CoverGenerator {
  CoverGenerator({
    required this._booksDao,
    required this._registry,
    required this._fileStore,
  });

  final BooksDao _booksDao;
  final FormatRegistry _registry;
  final Future<BookFileStore> _fileStore;

  final _log = AppLogger();

  /// 本进程内已尝试过的 bookId（含成功/失败/无封面），防重复解析与重试。
  final Set<String> _attempted = {};

  /// 正在生成中的 bookId（同书不并发跑两次）。
  final Set<String> _inFlight = {};

  /// 回填批量任务进行中标记（防批量任务自身重入）。
  bool _backfillRunning = false;

  /// 为单本书补生成封面（下载完成后调用）。返回是否写入成功。
  ///
  /// 幂等：coverPath 已登记、正文未落盘、找不到 handler、无封面字节、
  /// 解析失败——都直接返回 false，不改动数据库。永不抛出。
  Future<bool> generateForBook(String bookId) async {
    if (_attempted.contains(bookId) || !_inFlight.add(bookId)) return false;
    try {
      return await _generateInner(bookId);
    } catch (e, s) {
      _log.warn('封面补生成失败（本次会话内跳过）：bookId=$bookId');
      _log.error('封面补生成异常详情', e, s);
      return false;
    } finally {
      // 成功已写 coverPath（DB 查询自然不再命中）；失败/无封面记入已尝试，
      // 本进程内不重试（下次重启重新尝试）。
      _attempted.add(bookId);
      _inFlight.remove(bookId);
    }
  }

  Future<bool> _generateInner(String bookId) async {
    final book = await _booksDao.getById(bookId);
    final localPath = book?.localPath;
    if (book == null || localPath == null || localPath.isEmpty) return false;
    if ((book.coverPath ?? '').isNotEmpty) return false; // 幂等：已有封面。
    final handler = _registry.byFormatId(book.format);
    if (handler == null) return false;

    final file = await BookFile.fromPath(localPath);
    final parsed = await handler.parseMetadata(file); // handler 保证不抛。
    final store = await _fileStore;
    final coverPath = await writeCoverFile(store, bookId, parsed.coverBytes);
    if (coverPath == null) return false; // txt/md/pdf 等无封面：跳过。

    await _booksDao.updateCoverPath(book.bookId, coverPath);
    _log.info('封面补生成：bookId=$bookId');
    return true;
  }

  /// 存量回填：对 `localPath != null && coverPath == null` 的书逐本补生成。
  ///
  /// 应用启动时调用一次；批量内单本失败静默跳过（[generateForBook] 已兜），
  /// 任务级异常也吞掉（封面是旁路，不阻塞启动/书库）。并发调用只跑一次。
  Future<void> backfillMissing() async {
    if (_backfillRunning) return;
    _backfillRunning = true;
    try {
      final pending = await _booksDao.missingCovers();
      for (final book in pending) {
        await generateForBook(book.bookId);
      }
    } catch (e, s) {
      _log.error('封面存量回填异常', e, s);
    } finally {
      _backfillRunning = false;
    }
  }
}

/// 封面生成器（进程级单例：防重入集合随进程存活）。
final coverGeneratorProvider = Provider<CoverGenerator>((ref) {
  return CoverGenerator(
    booksDao: ref.watch(booksDaoProvider),
    registry: ref.watch(formatRegistryProvider),
    fileStore: ref.watch(bookFileStoreProvider.future),
  );
});
