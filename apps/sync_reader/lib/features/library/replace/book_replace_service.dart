/// FR-410 文件替换服务（详情页"重新选择文件"入口的执行层）。
///
/// 流程（docs/05 §6 不变式 3 的 app 侧接线，云端由 sync_core 引擎负责）：
/// 1. 校验：目标书存在且有本地正文（占位书不可替换）、扩展名已注册；
/// 2. 新文件落盘：同格式覆盖原路径；跨格式写 `resolveBookPath(bookId, 新扩展名)`；
/// 3. 流式计算 SHA-256（对落盘后的文件算，行内 hash 与磁盘内容一致）；
/// 4. 重解析元数据（失败不阻塞替换——元数据列保留旧值，仅文件指征列更新）；
/// 5. 更新 books 行：文件指征列经 `DriftLocalLibrary.updateBookFileInfo`
///    （format 变化时自动重探 localPath），重解析列经 `BooksDao.updateParsedMeta`；
///    行更新全部完成后才调云端推送（引擎从行构建 meta，顺序不可颠倒）；
/// 6. 云端推送：`SyncFacade.replaceBookContent`（幂等，失败下次同步自动重试）。
///
/// 依赖全部构造注入，便于测试（内存库 + 临时目录 + 假 handler + 假推送）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:sync_core/sync_core.dart';

import '../../../app/providers.dart';
import '../../../core/content_hasher.dart';
import '../../../data/db/daos/books_dao.dart';
import '../../../data/files/book_file_store.dart';
import '../../../data/sync/drift_local_library.dart';
import '../../reader/contract/book_file.dart';
import '../../reader/contract/format_registry.dart';
import '../../sync/sync_facade.dart';
import '../../sync/sync_status.dart' show syncErrorText;
import '../import/cover_generator.dart' show writeCoverFile;

/// 文件选择器的过滤扩展名（当前注册格式；新格式注册后在此追加）。
const replaceAllowedExtensions = ['txt', 'epub', 'md', 'pdf'];

/// 替换结果状态。
enum BookReplaceStatus {
  /// 本地替换 + 云端推送成功。
  success,

  /// 本地替换成功；未配置同步（云端未动，本地优先语义）。
  localOnly,

  /// 本地替换成功；云端推送失败（引擎幂等，下次同步自动重试）。
  cloudFailed,

  /// 本地替换失败（书缺失/格式不支持/IO 异常），文件与行都未动。
  localFailed,
}

/// 一次替换的结果（UI 据此出提示文案）。
class BookReplaceResult {
  const BookReplaceResult({required this.status, this.reason});

  final BookReplaceStatus status;

  /// localFailed = 本地失败原因；cloudFailed = 云端失败分类文案；其余 null。
  final String? reason;

  /// 本地替换是否已生效（本地失败时行与文件都保持原样）。
  bool get localReplaced => status != BookReplaceStatus.localFailed;

  /// Snackbar 文案。
  String toMessage() => switch (status) {
    BookReplaceStatus.success => '正文已替换并开始同步',
    BookReplaceStatus.localOnly => '本地文件已替换（未配置同步，云端未更新）',
    BookReplaceStatus.cloudFailed => '本地已替换，云端推送失败（$reason），下次同步自动重试',
    BookReplaceStatus.localFailed => '替换失败：$reason',
  };
}

/// 云端推送回调（行更新完成后调用；返回 null = 未配置同步）。
typedef ReplaceCloudPush = Future<SyncReport?> Function(String bookId);

/// 文件选择器抽象：把 `file_picker` 挡在接口后面，测试注入假实现
/// （同 batch_import 的 DirectoryPicker 模式）。
abstract interface class ReplaceFilePicker {
  /// 返回所选文件的绝对路径；用户取消返回 null（调用方静默返回）。
  Future<String?> pickBookFile();
}

/// 默认实现：file_picker v13 静态 API，按注册扩展名过滤单选。
final class FilePickerReplaceFilePicker implements ReplaceFilePicker {
  const FilePickerReplaceFilePicker();

  @override
  Future<String?> pickBookFile() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '选择新的书籍文件',
      type: FileType.custom,
      allowedExtensions: replaceAllowedExtensions,
    );
    for (final file in files) {
      final path = file.path;
      if (path != null && path.isNotEmpty) return path;
    }
    return null;
  }
}

/// 文件选择器 provider（测试 override 注入假实现）。
final replaceFilePickerProvider = Provider<ReplaceFilePicker>(
  (ref) => const FilePickerReplaceFilePicker(),
);

/// 文件替换服务。
class BookReplaceService {
  BookReplaceService({
    required this._booksDao,
    required this._registry,
    required this._fileStore,
    required this._library,
    required this._pushToCloud,
  });

  final BooksDao _booksDao;
  final FormatRegistry _registry;
  final Future<BookFileStore> _fileStore;
  final DriftLocalLibrary _library;
  final ReplaceCloudPush _pushToCloud;

  /// 把 [sourcePath] 的新文件替换为 [bookId] 的正文（本地落盘 + 行更新 +
  /// 云端推送）。永不抛出：本地失败折算为 localFailed，云端失败由引擎
  /// 折算进报告（幂等可重放）。
  Future<BookReplaceResult> replaceFile({
    required String bookId,
    required String sourcePath,
  }) async {
    final book = await _booksDao.getById(bookId);
    if (book == null) {
      return const BookReplaceResult(
        status: BookReplaceStatus.localFailed,
        reason: '书籍不存在',
      );
    }
    final localPath = book.localPath;
    if (localPath == null || localPath.isEmpty) {
      return const BookReplaceResult(
        status: BookReplaceStatus.localFailed,
        reason: '本书没有本地正文（占位书不可替换）',
      );
    }
    final ext = p.extension(sourcePath).replaceFirst('.', '').toLowerCase();
    if (ext.isEmpty) {
      return const BookReplaceResult(
        status: BookReplaceStatus.localFailed,
        reason: '无法识别文件格式',
      );
    }
    final handler = _registry.byExtension(
      ext,
      magicHeader: await _readMagicHeader(File(sourcePath)),
    );
    if (handler == null) {
      return BookReplaceResult(
        status: BookReplaceStatus.localFailed,
        reason: '不支持的格式（.$ext）',
      );
    }

    try {
      final store = await _fileStore;
      final sameFormat = ext == book.format;
      // 新文件落盘：同格式覆盖原路径；跨格式写新扩展名路径。
      final targetPath = sameFormat
          ? localPath
          : store.resolveBookPath(bookId, ext);
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      await File(sourcePath).copy(targetPath);

      // 流式哈希对落盘后的文件计算，保证行内 hash 与磁盘内容一致。
      final contentHash = await ContentHasher.hashFile(target);
      final sizeBytes = await target.length();

      // 重解析元数据：handler 基类约定解析失败降级不抛出；此处再防御一层，
      // 万一 handler 违约也不阻塞替换——元数据列保留旧值，仅文件指征列更新。
      String? title;
      String? author;
      String? tocFingerprint;
      String? coverPath; // null = 保留旧封面
      try {
        final parsed = await handler.parseMetadata(
          BookFile(
            path: targetPath,
            fileName: p.basename(sourcePath),
            sizeBytes: sizeBytes,
          ),
        );
        final parsedTitle = parsed.title.trim();
        title = parsedTitle.isEmpty
            ? _fallbackTitle(p.basename(sourcePath))
            : parsed.title;
        author = parsed.author;
        tocFingerprint = parsed.tocFingerprint;
        // 无封面字节（txt/md 等或提取失败）→ 保留旧封面，不写空值。
        coverPath = await writeCoverFile(store, bookId, parsed.coverBytes);
      } catch (_) {}

      // 行更新：先文件指征列（format 变化时自动重探 localPath 到新路径），
      // 再重解析列；全部完成后才允许推云端（引擎从行构建 meta）。
      await _library.updateBookFileInfo(
        bookId,
        fileName: p.basename(sourcePath),
        contentHash: contentHash,
        sizeBytes: sizeBytes,
        format: ext,
      );
      await _booksDao.updateParsedMeta(
        bookId,
        title: title,
        author: author,
        tocFingerprint: tocFingerprint,
        coverPath: coverPath,
      );

      // 跨格式：新路径已登记 → 删除旧格式正文文件。放在行更新成功之后，
      // 替换中途失败时旧文件仍可打开（永不让书变"占位"）。
      if (!sameFormat) {
        final oldFile = File(localPath);
        if (await oldFile.exists()) await oldFile.delete();
      }

      // 云端推送（用户显式操作，门面侧不受 autoSyncEnabled 门控）。
      final report = await _pushToCloud(bookId);
      if (report == null) {
        return const BookReplaceResult(status: BookReplaceStatus.localOnly);
      }
      if (report.success) {
        return const BookReplaceResult(status: BookReplaceStatus.success);
      }
      return BookReplaceResult(
        status: BookReplaceStatus.cloudFailed,
        reason: _firstErrorText(report),
      );
    } catch (e) {
      return BookReplaceResult(
        status: BookReplaceStatus.localFailed,
        reason: e.toString(),
      );
    }
  }

  /// 报告中的首个错误 → 分类文案（phaseError 优先）。
  String _firstErrorText(SyncReport report) {
    final phase = report.phaseError;
    if (phase != null) return syncErrorText(phase);
    for (final result in report.results) {
      if (!result.ok && result.error != null) {
        return syncErrorText(result.error!);
      }
    }
    return '同步未完成';
  }

  /// 文件名兜底书名（去扩展名，对齐导入服务）。
  String _fallbackTitle(String fileName) {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  /// 读文件头 8 字节作魔数（文件不可读时返回空字节，不阻断替换）。
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

/// 替换服务 provider（云端推送经同步门面；测试可整体覆盖）。
final bookReplaceServiceProvider = Provider<BookReplaceService>((ref) {
  return BookReplaceService(
    booksDao: ref.watch(booksDaoProvider),
    registry: ref.watch(formatRegistryProvider),
    fileStore: ref.watch(bookFileStoreProvider.future),
    library: ref.watch(driftLocalLibraryProvider),
    pushToCloud: (bookId) =>
        ref.read(syncFacadeProvider).replaceBookContent(bookId),
  );
});
