/// 本地导入流水线（FR-101/102）：逐文件
/// `哈希 → 去重 → 生成 ULID → 解析元数据 → 封面落盘 → 复制正文 → upsert`。
///
/// 设计约定：
/// - 全程异步（流式哈希 + IO 复制），不阻塞 UI；元数据解析的降级由
///   handler 基类保证（解析失败也有文件名元数据），本层不再兜底解析异常；
/// - 单文件失败不中断整批：异常计入 [ImportSummary.failures] 后继续；
/// - 去重双保险：库内按 contentHash 查询 + 同批次内存 Set（FR-101）；
/// - 「同时上传到云端」开关（docs/10 §4.7c / Q18）：默认勾选＝现行为；
///   取消勾选的书写入 `local_only_books`，同步引擎完全看不见它。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/content_hasher.dart';
import '../../../core/ulid.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/daos/books_dao.dart';
import '../../../data/db/daos/local_only_books_dao.dart';
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

/// 游离文件挂回结果（FR-408：恢复挂回的去重分流）。
class OrphanAdoptResult {
  /// 已挂回：生成新 bookId 并登记入库。
  const OrphanAdoptResult.adopted(this.book) : duplicateOf = null;

  /// 库内已有同 hash 书（[duplicateOf] 为其书名）：不重复挂回，
  /// 游离文件保持原样（冗余，用户可引导彻底删除）。
  const OrphanAdoptResult.duplicate(this.duplicateOf) : book = null;

  /// 挂回成功时的新书行。
  final Book? book;

  /// 去重命中时的已有书名。
  final String? duplicateOf;

  bool get adopted => book != null;

  bool get isDuplicate => duplicateOf != null;
}

/// 书籍导入服务。依赖经构造注入，便于测试（内存库 + 临时目录存储 + 假 handler）。
class BookImportService {
  BookImportService({
    required this._booksDao,
    required this._registry,
    required this._fileStore,
    this.localOnlyDao,
  });

  final BooksDao _booksDao;
  final FormatRegistry _registry;
  final Future<BookFileStore> _fileStore;

  /// 仅本地标记表（docs/10 §4.7c）：未注入时「不上传」开关退化为旧行为
  /// （照常参与同步），生产装配必须注入。
  final LocalOnlyBooksDao? localOnlyDao;

  /// 导入一批本地文件（路径来自文件选择器）。返回汇总；
  /// [onProgress] 在每个文件处理完后回调一次。
  ///
  /// [uploadToCloud] 对应导入弹窗的「同时上传到云端」勾选（默认 true）：
  /// - `true`（默认，现行为）：导入的书**不**标记为仅本地 → 下次全量同步走
  ///   diff 第 7a 行（本地新书从未推送过）自动上架（推 meta + 传正文）；
  /// - `false`：导入完成后把该书写入 `local_only_books` → 同步引擎完全
  ///   看不见它（既不推 meta 也不传正文），书库角标显示「仅本地」。
  ///
  /// 重复导入（同 contentHash 命中已有书）时的语义：**勾选状态落到已有书上**
  /// ——勾选则清除该书的仅本地标记（恢复为可上架），取消则写入标记。
  Future<ImportSummary> importFiles(
    List<String> paths, {
    void Function(ImportProgress progress)? onProgress,
    bool uploadToCloud = true,
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
          uploadToCloud: uploadToCloud,
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
    required bool uploadToCloud,
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
      // 重复导入：勾选状态落到已有书上（勾选 → 解除仅本地；取消 → 标记仅本地）。
      await _applyLocalOnlyMark(existing.bookId, uploadToCloud);
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
    // 「不上传」：标记为仅本地（同步引擎看不见它，docs/10 §4.7c）。
    await _applyLocalOnlyMark(bookId, uploadToCloud);
    summary.imported.add(book);
  }

  /// 落实「同时上传到云端」勾选状态到本地标记表。
  Future<void> _applyLocalOnlyMark(String bookId, bool uploadToCloud) async {
    final dao = localOnlyDao;
    if (dao == null) return;
    if (uploadToCloud) {
      await dao.clearLocalOnly(bookId);
    } else {
      await dao.markLocalOnly(bookId);
    }
  }

  /// 游离正文文件挂回书库（FR-408 游离文件面板，docs/04 §7.1.3 重关联）。
  ///
  /// 流程：hash 只算一次（move 不改内容，挂回后无需复算）→ 库内同 hash
  /// 去重分流（命中则原文件不动，返回 duplicate）→ 生成新 ULID → 元数据
  /// 解析（move 前做，文件还在旧路径）→ 同盘 rename 进平铺书库路径 →
  /// 封面落盘 → 登记 books 行。云端收敛是自动的：新书的 dirty meta 下次
  /// 同步走 §5.3 哈希去重或 §7.2 复活路径，进度按 LWW 尽力恢复。
  ///
  /// 不支持的扩展名抛 [FormatException]（面板扫描已过滤，此为防御性兜底）。
  Future<OrphanAdoptResult> adoptExistingFile({
    required String filePath,
  }) async {
    final bookFile = await BookFile.fromPath(filePath);
    final handler = _registry.byExtension(
      bookFile.ext,
      magicHeader: await _readMagicHeader(bookFile.file),
    );
    if (handler == null) {
      throw FormatException('不支持的格式（.${bookFile.ext}）', filePath);
    }

    // 1. 内容哈希（旧路径上算一次）+ 库内去重：已有同 hash 书 → 不重复挂回。
    final contentHash = await ContentHasher.hashFile(bookFile.file);
    final existing = await _booksDao.getByContentHash(contentHash);
    if (existing != null) {
      return OrphanAdoptResult.duplicate(existing.title);
    }

    final store = await _fileStore;
    final bookId = generateUlid();

    // 2. 元数据解析（handler 保证失败降级为文件名元数据），move 前执行。
    final parsed = await handler.parseMetadata(bookFile);

    // 3. 同盘 rename 挂回平铺路径（books/{bookId}.{ext}），原路径消失。
    final localPath = await store.adoptBookFile(
      bookId: bookId,
      ext: bookFile.ext,
      source: bookFile.file,
    );

    // 4. 封面落盘 + 登记 books 行（sizeBytes 取 move 前 stat，rename 不变）。
    final coverPath = await writeCoverFile(store, bookId, parsed.coverBytes);
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
    return OrphanAdoptResult.adopted(book);
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
