/// 本地导入流水线（FR-101/102）：逐文件
/// `哈希 → 去重 → 生成 ULID → 解析元数据 → 封面落盘 → 复制正文 → upsert`。
///
/// 设计约定：
/// - 全程异步（流式哈希 + IO 复制），不阻塞 UI；元数据解析的降级由
///   handler 基类保证（解析失败也有文件名元数据），本层不再兜底解析异常；
/// - 单文件失败不中断整批：异常计入 [ImportSummary.failures] 后继续；
/// - 去重双保险：库内按 contentHash 查询 + 同批次内存 Set（FR-101）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/content_hasher.dart';
import '../../../core/ulid.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/daos/books_dao.dart';
import '../../../data/files/book_file_store.dart';
import '../../reader/contract/book_file.dart';
import '../../reader/contract/format_registry.dart';
import 'cover_generator.dart' show writeCoverFile;

/// 单文件导入进度（UI Snackbar 用）。
class ImportProgress {
  const ImportProgress({
    required this.completed,
    required this.total,
    required this.currentName,
  });

  /// 已处理完的文件数（不含当前）。
  final int completed;

  /// 本批文件总数。
  final int total;

  /// 正在处理的文件名。
  final String currentName;
}

/// 一批导入的结果汇总。
class ImportSummary {
  final List<Book> imported = [];

  /// 命中去重而跳过的文件：`文件名 → 已存在的书名`（提示"《X》已存在"）。
  final Map<String, String> duplicates = {};

  /// 失败的文件：`文件名 → 原因`。
  final Map<String, String> failures = {};

  /// 本批文件总数。
  int get total => imported.length + duplicates.length + failures.length;

  /// 是否所有文件都成功导入。
  bool get allImported => duplicates.isEmpty && failures.isEmpty;

  /// 汇总提示文案（Snackbar 正文）。
  String toMessage() {
    if (total == 0) return '没有选择任何文件';
    final lines = <String>['导入完成：新增 ${imported.length} 本'];
    for (final entry in duplicates.entries) {
      lines.add('《${entry.value}》已存在，已复用原条目（${entry.key}）');
    }
    for (final entry in failures.entries) {
      lines.add('${entry.key} 导入失败：${entry.value}');
    }
    return lines.join('\n');
  }
}

/// 书籍导入服务。依赖经构造注入，便于测试（内存库 + 临时目录存储 + 假 handler）。
class BookImportService {
  BookImportService({
    required this._booksDao,
    required this._registry,
    required this._fileStore,
  });

  final BooksDao _booksDao;
  final FormatRegistry _registry;
  final Future<BookFileStore> _fileStore;

  /// 导入一批本地文件（路径来自文件选择器）。返回汇总；
  /// [onProgress] 在每个文件处理完后回调一次。
  Future<ImportSummary> importFiles(
    List<String> paths, {
    void Function(ImportProgress progress)? onProgress,
  }) async {
    final summary = ImportSummary();
    final store = await _fileStore;
    final batchHashes = <String>{};
    var done = 0;
    for (final path in paths) {
      final name = p.basename(path);
      try {
        await _importOne(
          path: path,
          name: name,
          store: store,
          batchHashes: batchHashes,
          summary: summary,
        );
      } catch (e) {
        summary.failures[name] = e.toString();
      }
      done++;
      onProgress?.call(
        ImportProgress(completed: done, total: paths.length, currentName: name),
      );
    }
    return summary;
  }

  Future<void> _importOne({
    required String path,
    required String name,
    required BookFileStore store,
    required Set<String> batchHashes,
    required ImportSummary summary,
  }) async {
    final bookFile = await BookFile.fromPath(path);

    // 1. 找 handler（带文件头魔数供未来嗅探；基线 handler 只看扩展名）。
    final handler = _registry.byExtension(
      bookFile.ext,
      magicHeader: await _readMagicHeader(bookFile.file),
    );
    if (handler == null) {
      summary.failures[name] = '不支持的格式（.${bookFile.ext}）';
      return;
    }

    // 2. 流式计算内容哈希 + 去重（库内 + 同批次，FR-101）。
    final contentHash = await ContentHasher.hashFile(bookFile.file);
    final existing = await _booksDao.getByContentHash(contentHash);
    if (existing != null) {
      summary.duplicates[name] = existing.title;
      return;
    }
    if (!batchHashes.add(contentHash)) {
      summary.duplicates[name] = _fallbackTitle(bookFile);
      return;
    }

    // 3. 生成 bookId，解析元数据（handler 保证失败降级为文件名元数据）。
    final bookId = generateUlid();
    final parsed = await handler.parseMetadata(bookFile);

    // 4. 封面落盘（有字节才写；写入与下载后补生成共用 writeCoverFile）。
    final coverPath = await writeCoverFile(store, bookId, parsed.coverBytes);

    // 5. 复制正文入库（原文件保留在用户处），再写库行。
    final localPath = await store.importCopy(
      bookId: bookId,
      ext: bookFile.ext,
      source: bookFile.file,
    );
    final book = Book(
      bookId: bookId,
      title: parsed.title.trim().isEmpty
          ? _fallbackTitle(bookFile)
          : parsed.title,
      author: parsed.author,
      format: handler.formatId,
      fileName: bookFile.fileName,
      localPath: localPath,
      contentHash: contentHash,
      sizeBytes: bookFile.sizeBytes,
      coverPath: coverPath,
      tocFingerprint: parsed.tocFingerprint,
      addedAt: DateTime.now().millisecondsSinceEpoch,
      totalSeconds: 0,
    );
    await _booksDao.upsert(book);
    summary.imported.add(book);
  }

  /// 文件名兜底书名（去扩展名）。
  String _fallbackTitle(BookFile file) {
    final name = file.fileName;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 读文件头 8 字节作魔数（文件不可读时返回空字节，不得阻断导入）。
  Future<Uint8List> _readMagicHeader(File file) async {
    try {
      final raf = await file.open();
      try {
        return await raf.read(8);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return Uint8List(0);
    }
  }
}
