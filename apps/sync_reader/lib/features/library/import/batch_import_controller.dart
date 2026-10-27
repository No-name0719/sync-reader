/// 批量导入（FR-109）确认页的状态控制器与目录选择器抽象。
///
/// 职责：
/// - 扫描阶段：调 [BookScanner] 收集候选文件（快，纯文件系统遍历）；
/// - 分析阶段：逐个流式计算 contentHash（复用单本导入的
///   `ContentHasher`，大文件不载入内存），按"库内同 hash / 同批同 hash"
///   打"已存在"标记并默认取消勾选（FR-101 去重语义前置到清单）；
/// - 导入阶段：把选中的候选逐本交给 [BookImportService]（复用单本管线，
///   含入库级 hash 去重双保险），单本失败不中断，结束出汇总；
/// - 防重入：导入进行中（phase == importing）拒绝再次扫描 / 导入，
///   书库入口的菜单项据此禁用。
///
/// 候选的哈希分析在确认页打开后异步渐进进行（每完成一个更新一次状态），
/// UI 全程无阻塞调用，大文件也不冻结界面（FR-102 同款约束）。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../core/content_hasher.dart';
import '../../../data/db/daos/books_dao.dart';
import '../library_providers.dart' show bookImportServiceProvider;
import 'book_import_service.dart';
import 'book_scanner.dart';

/// 目录选择器抽象：把 `file_picker` 挡在接口后面，测试注入假实现
/// （widget 测试不依赖真实平台通道）。
abstract interface class DirectoryPicker {
  /// 返回所选目录绝对路径；用户取消返回 null（调用方静默返回）。
  Future<String?> pickDirectory();
}

/// 默认实现：file_picker v13 静态 API 选目录。
final class FilePickerDirectoryPicker implements DirectoryPicker {
  const FilePickerDirectoryPicker();

  @override
  Future<String?> pickDirectory() =>
      FilePicker.getDirectoryPath(dialogTitle: '选择要扫描的文件夹');
}

/// 目录选择器 provider（测试 override 注入假实现）。
final directoryPickerProvider = Provider<DirectoryPicker>(
  (ref) => const FilePickerDirectoryPicker(),
);

/// 清单页单个候选条目（不可变，变更即整行替换）。
class ImportCandidate {
  const ImportCandidate({
    required this.file,
    this.contentHash,
    this.duplicateOf,
    this.duplicateInBatch = false,
    this.selected = true,
  });

  /// 扫描到的文件静态信息。
  final ScannedFile file;

  /// 内容哈希（分析阶段补充；分析完成前为 null）。
  final String? contentHash;

  /// 重复来源：库内已有书名，或同批先出现的相对路径；null = 新书。
  /// 非 null 时默认不勾选（FR-109：已在书库的默认不勾）。
  final String? duplicateOf;

  /// true = 与同批先出现的候选重复（[duplicateOf] 为对方相对路径）；
  /// false = 与库内已有书重复（[duplicateOf] 为书名）。
  final bool duplicateInBatch;

  /// 是否勾选导入（新书默认勾选）。
  final bool selected;

  bool get isDuplicate => duplicateOf != null;

  ImportCandidate copyWith({
    String? contentHash,
    String? duplicateOf,
    bool? duplicateInBatch,
    bool? selected,
  }) => ImportCandidate(
    file: file,
    contentHash: contentHash ?? this.contentHash,
    duplicateOf: duplicateOf ?? this.duplicateOf,
    duplicateInBatch: duplicateInBatch ?? this.duplicateInBatch,
    selected: selected ?? this.selected,
  );
}

/// 确认页状态机阶段。
enum BatchImportPhase {
  /// 初始（未开始）。
  idle,

  /// 目录遍历中（通常毫秒级）。
  scanning,

  /// 哈希 / 去重分析中（渐进出结果）。
  analyzing,

  /// 清单就绪，可勾选导入。
  ready,

  /// 导入执行中（防重入窗口）。
  importing,

  /// 本轮导入已结束（保留汇总供展示；重新扫描即重置）。
  done,
}

/// 确认页状态。
class BatchImportState {
  const BatchImportState({
    this.phase = BatchImportPhase.idle,
    this.directoryPath,
    this.candidates = const [],
    this.truncated = false,
    this.skippedCount = 0,
    this.analyzedCount = 0,
    this.progress,
    this.summary,
    this.errorMessage,
  });

  final BatchImportPhase phase;

  /// 本轮扫描的根目录。
  final String? directoryPath;

  /// 候选清单（扫描期顺序 = 相对路径字典序）。
  final List<ImportCandidate> candidates;

  /// 扫描因达到上限被截断（清单不完整）。
  final bool truncated;

  /// 扫描时静默跳过的无法访问条目数。
  final int skippedCount;

  /// 分析阶段已完成的条数（进度展示：analyzedCount / candidates.length）。
  final int analyzedCount;

  /// 导入进行中的进度（阶段结束置空）。
  final ImportProgress? progress;

  /// 导入结果汇总（phase == done 时可读）。
  final ImportSummary? summary;

  /// 致命错误（根目录不可访问 / 导入启动失败等）；单本失败走 summary。
  final String? errorMessage;

  bool get importing => phase == BatchImportPhase.importing;

  /// 当前勾选的候选。
  List<ImportCandidate> get selectedCandidates =>
      candidates.where((c) => c.selected).toList(growable: false);

  /// 勾选总字节数（底部合计）。
  int get selectedBytes =>
      selectedCandidates.fold(0, (sum, c) => sum + c.file.sizeBytes);

  BatchImportState copyWith({
    BatchImportPhase? phase,
    String? directoryPath,
    List<ImportCandidate>? candidates,
    bool? truncated,
    int? skippedCount,
    int? analyzedCount,
    ImportProgress? progress,
    ImportSummary? summary,
    String? errorMessage,
    bool clearProgress = false,
    bool clearError = false,
  }) => BatchImportState(
    phase: phase ?? this.phase,
    directoryPath: directoryPath ?? this.directoryPath,
    candidates: candidates ?? this.candidates,
    truncated: truncated ?? this.truncated,
    skippedCount: skippedCount ?? this.skippedCount,
    analyzedCount: analyzedCount ?? this.analyzedCount,
    progress: clearProgress ? null : (progress ?? this.progress),
    summary: summary ?? this.summary,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// 批量导入确认页控制器。
///
/// 依赖经 ref 读取（与 `bookImportServiceProvider` 同套测试注入模式：
/// 容器级 override booksDao / bookImportService / formatRegistry）。
class BatchImportController extends Notifier<BatchImportState> {
  @override
  BatchImportState build() => const BatchImportState();

  /// 扫描 + 分析全程的防重入标记（状态机之外的进程内信号，
  /// 避免 analyzing 期间重复触发 startScan 造成双循环并发写状态）。
  bool _pipelineRunning = false;

  BooksDao get _booksDao => ref.read(booksDaoProvider);

  /// 选择目录并开始扫描 + 分析（确认页 initState 触发）。
  ///
  /// 导入进行中 / 流水线已在跑时静默忽略（防重入，FR-109 并发保护）。
  Future<void> startScan(String directoryPath) async {
    if (_pipelineRunning || state.importing) return;
    _pipelineRunning = true;
    // 重置为新扫描会话（清掉上轮的汇总与错误）。
    state = BatchImportState(
      phase: BatchImportPhase.scanning,
      directoryPath: directoryPath,
    );
    try {
      final result = await BookScanner(
        registry: ref.read(formatRegistryProvider),
      ).scan(Directory(directoryPath));
      if (result.rootMissing) {
        state = state.copyWith(
          phase: BatchImportPhase.ready,
          errorMessage: '目录不存在或无法访问',
        );
        return;
      }
      state = state.copyWith(
        phase: BatchImportPhase.analyzing,
        candidates: [
          for (final file in result.files) ImportCandidate(file: file),
        ],
        truncated: result.truncated,
        skippedCount: result.skippedCount,
      );
      await _analyzeCandidates();
    } catch (e) {
      state = state.copyWith(
        phase: BatchImportPhase.ready,
        errorMessage: '扫描失败：$e',
      );
    } finally {
      _pipelineRunning = false;
    }
  }

  /// 分析阶段：逐个流式计算哈希并标记去重（渐进更新，UI 不冻结）。
  ///
  /// - 库内同 hash → duplicateOf = 已有书名（FR-101 跨批次去重）；
  /// - 同批先出现的同 hash → duplicateOf = 对方相对路径（导入时经
  ///   BookImportService 批内去重复用）；
  /// - 单个文件哈希失败（中途消失等）不标记、保持默认勾选，
  ///   真正导入时由管线计入失败。
  Future<void> _analyzeCandidates() async {
    final seenHashes = <String, String>{}; // hash → 先出现候选的相对路径
    for (var i = 0; i < state.candidates.length; i++) {
      final candidate = state.candidates[i];
      try {
        final hash = await ContentHasher.hashFile(File(candidate.file.path));
        final existing = await _booksDao.getByContentHash(hash);
        var updated = candidate.copyWith(contentHash: hash);
        if (existing != null) {
          updated = updated.copyWith(duplicateOf: existing.title);
        } else if (seenHashes[hash] case final String firstPath) {
          updated = updated.copyWith(
            duplicateOf: firstPath,
            duplicateInBatch: true,
          );
        }
        // 首次标记为重复 → 默认不勾选（FR-109）；用户在分析期间对该行
        // 的手动勾选不被覆盖（只有"新检出重复"才改勾选）。
        if (updated.isDuplicate && !candidate.isDuplicate) {
          updated = updated.copyWith(selected: false);
        }
        seenHashes[hash] ??= candidate.file.relativePath;
        // 以最新 state 为底覆盖写：保留分析期间发生的其他状态变更。
        final candidates = [...state.candidates];
        candidates[i] = updated;
        state = state.copyWith(candidates: candidates, analyzedCount: i + 1);
      } catch (_) {
        // 哈希失败（文件中途消失等）：不标记，导入时由管线计入失败。
        state = state.copyWith(analyzedCount: i + 1);
      }
    }
    state = state.copyWith(phase: BatchImportPhase.ready);
  }

  /// 勾选/取消单个候选（导入进行中禁用）。
  void toggle(int index) {
    if (state.importing || index < 0 || index >= state.candidates.length) {
      return;
    }
    _setSelected(index, !state.candidates[index].selected);
  }

  /// 全选（含"已存在"项——导入时管线会去重复用，交由用户决定）。
  void selectAll() => _setAll(true);

  /// 反选。
  void invertSelection() {
    if (state.importing) return;
    _replaceCandidates([
      for (final c in state.candidates) c.copyWith(selected: !c.selected),
    ]);
  }

  /// 导入选中的候选（确认页底部按钮触发）。
  ///
  /// 返回汇总；不可导入（未就绪 / 无勾选 / 导入中）返回 null。
  /// 单本失败不中断（[BookImportService] 保证），结束后 phase → done。
  Future<ImportSummary?> importSelected() async {
    final current = state;
    if (current.phase != BatchImportPhase.ready || _pipelineRunning) {
      return null;
    }
    final paths = [for (final c in current.selectedCandidates) c.file.path];
    if (paths.isEmpty) return null;

    state = current.copyWith(
      phase: BatchImportPhase.importing,
      clearError: true,
    );
    try {
      final summary = await ref
          .read(bookImportServiceProvider)
          .importFiles(
            paths,
            onProgress: (p) {
              state = state.copyWith(progress: p);
            },
          );
      state = state.copyWith(
        phase: BatchImportPhase.done,
        summary: summary,
        clearProgress: true,
      );
      return summary;
    } catch (e) {
      state = state.copyWith(
        phase: BatchImportPhase.done,
        errorMessage: '导入失败：$e',
        clearProgress: true,
      );
      return null;
    }
  }

  void _setSelected(int index, bool selected) {
    final candidates = [...state.candidates];
    candidates[index] = candidates[index].copyWith(selected: selected);
    _replaceCandidates(candidates);
  }

  void _setAll(bool selected) {
    if (state.importing) return;
    _replaceCandidates([
      for (final c in state.candidates) c.copyWith(selected: selected),
    ]);
  }

  void _replaceCandidates(List<ImportCandidate> candidates) {
    state = state.copyWith(candidates: candidates);
  }
}

/// 批量导入控制器 provider（app 作用域：导入进行中跨页面可见）。
final batchImportControllerProvider =
    NotifierProvider<BatchImportController, BatchImportState>(
      BatchImportController.new,
    );

/// 批量导入汇总文案（确认页对话框 / 书库 Snackbar 共用）：
/// `成功 N / 跳过重复 M / 失败 K`，失败时附首条原因（FR-109 汇总语义）。
String batchImportSummaryMessage(ImportSummary summary) {
  if (summary.total == 0) return '没有可导入的文件';
  final buffer = StringBuffer('批量导入完成：成功 ${summary.imported.length} 本');
  if (summary.duplicates.isNotEmpty) {
    buffer.write('，跳过重复 ${summary.duplicates.length} 本');
  }
  if (summary.failures.isNotEmpty) {
    buffer.write('，失败 ${summary.failures.length} 本');
    final first = summary.failures.entries.first;
    buffer.write('\n首条失败：${first.key}（${first.value}）');
  }
  return buffer.toString();
}
