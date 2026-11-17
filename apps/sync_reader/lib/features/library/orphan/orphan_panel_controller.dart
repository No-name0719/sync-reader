/// 游离文件面板状态控制器（FR-408）。
///
/// 职责：
/// - 扫描：调 [OrphanFileService.scan]（只读，无 DB 写入）出清单；
/// - 自动重扫：订阅 `booksDao.watchAllBookIds()`（drift watch）——挂回
///   入库后 books 表变化即重扫；删除不动 books 表，操作完成后主动重扫；
/// - 懒解析标题：逐个 handler.parseMetadata 取书名，旁路进行（不阻塞
///   列表渲染），失败/解析中显示文件名主干；
/// - 防重入：恢复/删除进行中（busy）拒绝一切新操作，操作完成后重扫。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../reader/contract/book_file.dart';
import '../library_providers.dart' show bookImportServiceProvider;
import '../import/book_import_service.dart' show OrphanAdoptResult;
import 'orphan_book_file.dart';
import 'orphan_file_service.dart';

/// 面板状态。
class OrphanPanelState {
  const OrphanPanelState({
    this.scanning = false,
    this.orphans = const [],
    this.titles = const {},
    this.busy = false,
    this.errorMessage,
  });

  /// 扫描进行中（首扫 / 重扫）。
  final bool scanning;

  /// 当前游离文件清单（按文件名排序）。
  final List<OrphanBookFile> orphans;

  /// 懒解析出的书名：`path → 书名`（无条目 = 解析中或解析失败，显示主干）。
  final Map<String, String> titles;

  /// 恢复 / 删除操作进行中（防重入：冻结全部操作按钮）。
  final bool busy;

  /// 操作/扫描失败提示（横幅展示，下次操作前清空）。
  final String? errorMessage;

  /// 是否冻结行内操作（扫描中 + 操作中都冻结，防对旧路径并发操作）。
  bool get frozen => busy || scanning;

  OrphanPanelState copyWith({
    bool? scanning,
    List<OrphanBookFile>? orphans,
    Map<String, String>? titles,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) => OrphanPanelState(
    scanning: scanning ?? this.scanning,
    orphans: orphans ?? this.orphans,
    titles: titles ?? this.titles,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// 游离文件面板控制器。
class OrphanPanelController extends Notifier<OrphanPanelState> {
  @override
  OrphanPanelState build() {
    // drift watch：books 表 bookId 集合变化（挂回入库等）→ 自动重扫。
    // 订阅在 build 内注册，provider 销毁时随容器取消。
    final sub = ref.read(booksDaoProvider).watchAllBookIds().listen((_) {
      unawaited(refresh());
    });
    ref.onDispose(() => unawaited(sub.cancel()));
    // 首扫放到微任务：build 期间不得写状态。
    Future<void>.microtask(() {
      if (ref.mounted) refresh();
    });
    return const OrphanPanelState();
  }

  /// 重扫进行中标记（进程内防抖：drift 连发多帧只跑一轮扫描）。
  bool _reloading = false;

  /// 懒解析书名的在途 path 集合（防同一文件重复起解析任务）。
  final Set<String> _titleInFlight = {};

  /// 重扫清单（面板打开 / drift watch 触发 / 操作完成后）。
  ///
  /// 操作进行中跳过（操作完成后有显式重扫兜底）；并发调用只跑一轮。
  Future<void> refresh() async {
    if (state.busy || _reloading) return;
    _reloading = true;
    state = state.copyWith(scanning: true, clearError: true);
    try {
      final orphans = await ref.read(orphanFileServiceProvider).scan();
      if (!ref.mounted) return;
      state = state.copyWith(scanning: false, orphans: orphans);
      _resolveTitles();
    } catch (e) {
      if (!ref.mounted) return;
      state = state.copyWith(scanning: false, errorMessage: '扫描失败');
    } finally {
      _reloading = false;
    }
  }

  /// 挂回书库（FR-408 主操作）。返回挂回结果供页面出提示；
  /// 防重入窗口内 / 启动失败返回 null（错误见 [OrphanPanelState.errorMessage]）。
  Future<OrphanAdoptResult?> restore(OrphanBookFile orphan) async {
    if (state.frozen) return null;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final result = await ref
          .read(bookImportServiceProvider)
          .adoptExistingFile(filePath: orphan.path);
      // 目录形态挂回成功：正文已 rename 出去，容器通常已空——顺手移除
      //（duplicate 分支文件原地保留，容器一并保留）。
      if (result.adopted) {
        await ref.read(orphanFileServiceProvider).cleanupContainer(orphan);
      }
      state = state.copyWith(busy: false);
      // 入库已触发 drift watch 自动重扫；这里显式重扫兜底（删除同款时序）。
      await refresh();
      return result;
    } catch (e) {
      state = state.copyWith(busy: false, errorMessage: '挂回失败');
      return null;
    }
  }

  /// 彻底删除（页面二次确认后调用）。返回是否删除成功。
  Future<bool> delete(OrphanBookFile orphan) async {
    if (state.frozen) return false;
    state = state.copyWith(busy: true, clearError: true);
    try {
      await ref.read(orphanFileServiceProvider).deleteOrphan(orphan);
      state = state.copyWith(busy: false);
      // 删除不动 books 表 → drift watch 不会触发，主动重扫。
      await refresh();
      return true;
    } catch (e) {
      state = state.copyWith(busy: false, errorMessage: '删除失败');
      return false;
    }
  }

  /// 行展示标题：懒解析结果优先，解析中 / 失败显示文件名主干。
  String displayTitle(OrphanBookFile orphan) =>
      state.titles[orphan.path] ?? orphan.stem;

  /// 旁路懒解析：逐个文件取书名，完成一个刷新一行；不阻塞列表渲染，
  /// 单个失败静默保持主干（handler 基类通常不抛，此处防御性兜底）。
  void _resolveTitles() {
    final registry = ref.read(formatRegistryProvider);
    for (final orphan in state.orphans) {
      if (state.titles.containsKey(orphan.path)) continue;
      if (!_titleInFlight.add(orphan.path)) continue;
      unawaited(() async {
        try {
          final handler = registry.byExtension(orphan.ext);
          if (handler == null) return;
          // 扫描已带 stat 信息：直接构造 BookFile，避免再触碰磁盘
          //（也让 fakeAsync 的 widget 测试可以用纯内存假 handler）。
          final file = BookFile(
            path: orphan.path,
            fileName: orphan.fileName,
            sizeBytes: orphan.sizeBytes,
          );
          final parsed = await handler.parseMetadata(file);
          final title = parsed.title.trim();
          if (!ref.mounted || title.isEmpty) return;
          state = state.copyWith(titles: {...state.titles, orphan.path: title});
        } catch (_) {
          // 解析失败：保持文件名主干。
        } finally {
          _titleInFlight.remove(orphan.path);
        }
      }());
    }
  }
}

/// 游离文件面板控制器 provider（autoDispose：退出面板即销毁，
/// drift 订阅随容器取消，不在面板外空转扫描）。
final orphanPanelControllerProvider =
    NotifierProvider.autoDispose<OrphanPanelController, OrphanPanelState>(
      OrphanPanelController.new,
    );
