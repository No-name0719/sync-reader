import 'dart:io';

import '../diff/diff_engine.dart';
import '../model/book_meta.dart';

/// 本地书库纯接口（docs/05 §5 `books` / `progress` 表 + 正文文件系统，
/// 本地优先视角）。app 侧以 drift + 应用私有目录实现；引擎只依赖本接口。
///
/// 正文文件相关的路径/落盘方法让引擎无需感知 app 的目录布局；
/// 引擎允许使用 dart:io [File]，但目录约定一律经由本接口获得。
abstract interface class LocalLibrary {
  /// 全部书籍快照（含占位书；书库视图，tombstone 应用后即消失）。
  Future<List<LocalBookSnapshot>> listBooks();

  /// 单本快照；不存在返回 null。
  Future<LocalBookSnapshot?> book(String bookId);

  /// 应用远端 meta 到本地书库视图与进度（docs/04 §5.1 第 2/5 行）。
  ///
  /// - 正常 meta：覆盖书信息与进度（dirty 置 false）；本地正文缺失则保持占位；
  /// - tombstone：从书库视图移除（正文文件保留为游离文件，docs/04 §7.1.2）。
  Future<void> applyRemoteMeta(BookMeta meta);

  /// 标记"云端缺失"（docs/04 §5.1 第 7b 行：保留本地待用户处理）。
  Future<void> markCloudMissing(String bookId);

  /// 哈希去重并入（docs/04 §5.3 / docs/05 §4.3）：本地条目 [localBookId]
  /// 并入云端书 [cloudBookId]——保留云端 bookId 与其 rev 链，本地正文文件
  /// 挪到云端书名下，进度按 updatedAt 与云端 LWW 合并。
  Future<void> adoptCloudBook({
    required String localBookId,
    required String cloudBookId,
    required BookMeta cloudMeta,
  });

  /// 由本地行构建**待推送 meta**（docs/04 §2：推送时才定 rev/设备信息）。
  Future<BookMeta> buildLocalMeta(
    String bookId, {
    required int rev,
    required String deviceId,
    required String deviceName,
    required DateTime now,
  });

  /// 本地正文文件路径；占位书（正文缺失）返回 null。
  Future<String?> localContentPath(String bookId);

  /// 正文最终落盘路径（不存在不创建实体文件，仅约定路径）。
  Future<String> contentTargetPath(String bookId, {required String format});

  /// 下载用 `.part` 临时文件路径。
  Future<String> contentPartPath(String bookId, {required String format});

  /// 下载产物登记转正：[contentFile] 为最终落盘路径
  /// （TransferQueue 已完成 `.part` → target 的原子 rename）。
  /// 实现负责登记本地路径并清除占位标记。
  Future<void> commitContentFile(String bookId, String contentFile);

  /// 文件替换的本地行登记（FR-410，docs/05 §6 不变式 3 的显式出口）。
  ///
  /// app 层先把新文件落盘、完成重解析，再调用本方法更新 `books` 行的
  /// 文件指征列（仅更新非 null 实参对应的列）；随后调
  /// [SyncEngine.replaceBookContent] 推送 meta 与正文。title/toc/封面等
  /// 重解析结果由 app 自行更新，不经本方法。书不存在抛 [StateError]。
  Future<void> updateBookFileInfo(
    String bookId, {
    String? fileName,
    String? contentHash,
    int? sizeBytes,
    String? format,
  });
}
