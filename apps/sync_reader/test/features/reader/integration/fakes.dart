/// 阅读集成测试替身（test/features/reader/integration 专用）：
/// 假 handler / 渲染器 / 控制器，替代真实渲染器（做法参考
/// test/library/fake_handler.dart，但暴露可观测记录点）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/book_format_handler.dart';
import 'package:sync_reader/features/reader/contract/book_renderer.dart';
import 'package:sync_reader/features/reader/contract/parsed_book.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_controller.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';

/// 假控制器：记录 restore / jumpTo / dispose；定位值可注入。
class FakeReaderController extends ReaderController {
  /// restore 收到的锚点序列。
  final List<ProgressAnchor> restoreCalls = [];

  /// jumpTo 收到的目录条目序列。
  final List<TocEntry> jumpCalls = [];

  /// 翻页调用序列（+1 = nextPage / -1 = previousPage，FR-209）。
  final List<int> turnCalls = [];

  /// dispose 次数。
  int disposeCount = 0;

  /// currentLocator 的返回值（模拟用户已读到的位置）。
  ProgressAnchor locator = ProgressAnchor.empty;

  /// percent 的返回值。
  double percentValue = 0;

  /// 翻页的返回值（true = 真的翻了；false = 已在首/末页 = 边界）。
  ///
  /// v1.4.4：宿主据此决定是否播放**统一边界回弹**（docs/10 §9.21）。
  bool turnResult = true;

  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async {
    restoreCalls.add(saved);
    return ReaderRestoreResult(
      mode: saved.hasProgress
          ? ReaderRestoreMode.exact
          : ReaderRestoreMode.noProgress,
      applied: saved,
    );
  }

  @override
  ProgressAnchor get currentLocator => locator;

  @override
  double get percent => percentValue;

  @override
  Future<void> jumpTo(TocEntry entry) async => jumpCalls.add(entry);

  @override
  Future<bool> nextPage() async {
    turnCalls.add(1);
    return turnResult;
  }

  @override
  Future<bool> previousPage() async {
    turnCalls.add(-1);
    return turnResult;
  }

  @override
  void dispose() => disposeCount++;
}

/// 假渲染器：空白视图；记录 applySettings；可主动模拟进度上报。
class FakeRenderer extends BookRenderer {
  @override
  final FakeReaderController controller = FakeReaderController();

  /// 最近一次 applySettings 收到的设置（未调用为 null）。
  ReaderSettings? lastApplied;

  /// applySettings 调用次数。
  int applySettingsCount = 0;

  /// 是否已销毁。
  bool disposed = false;

  /// isTocEntryCurrent 的命中标题（null = 全不命中；目录「当前」标记测试用）。
  String? currentTocTitle;

  /// 模拟渲染器节流后的进度上报。
  void emitProgress(ProgressAnchor anchor, double percent) =>
      controller.onProgressChanged?.call(anchor, percent);

  @override
  Widget buildView(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('fake-renderer-view'));

  /// 契约外的公开约定扩展（真实渲染器均实现）：设置热应用入口。
  void applySettings(ReaderSettings settings) {
    lastApplied = settings;
    applySettingsCount++;
  }

  /// 契约外公开约定（v1.1 A8）：当前章比对——按注入的命中标题判断。
  @override
  bool isTocEntryCurrent(TocEntry entry) => entry.title == currentTocTitle;

  @override
  void dispose() {
    disposed = true;
    controller.dispose();
  }
}

/// 假 handler：parseMetadata 固定返回；createRenderer 返回注入的假渲染器
/// 或抛出 [createRendererError]（错误页测试用）。
class FakeHandler implements BookFormatHandler {
  FakeHandler({
    this.formatId = 'txt',
    Set<String>? extensions,
    this.toc = const [],
    this.renderer,
    this.createRendererError,
  }) : extensions = extensions ?? const {'txt'};

  @override
  final String formatId;

  /// 支持的扩展名集合。
  final Set<String> extensions;

  /// parseMetadata 固定返回的目录。
  final List<TocEntry> toc;

  /// createRenderer 返回的渲染器（复用实例，测试持有引用做断言）。
  final FakeRenderer? renderer;

  /// 非 null 时 createRenderer 抛出该错误（模拟渲染器创建失败）。
  final Object? createRendererError;

  /// createRenderer 调用次数。
  int createRendererCount = 0;

  /// createRenderer 每次收到的设置（按序；用于断言「渲染器按什么设置创建」）。
  final List<ReaderSettings> createdSettings = [];

  @override
  bool canHandle(String ext, Uint8List magicHeader) =>
      extensions.contains(ext.toLowerCase());

  @override
  Future<ParsedBook> parseMetadata(BookFile file) async => ParsedBook(
    title: '假书名',
    author: '假作者',
    toc: toc,
    tocFingerprint: 'tfp:0123456789abcdef',
  );

  @override
  Future<BookRenderer> createRenderer(
    BookFile file,
    ReaderSettings settings,
    ProgressAnchor anchor,
  ) async {
    createRendererCount++;
    createdSettings.add(settings);
    final error = createRendererError;
    if (error != null) throw error;
    return renderer ?? FakeRenderer();
  }
}
