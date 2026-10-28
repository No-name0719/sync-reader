/// 占位渲染器：M1 基线 handler 的 createRenderer 返回值。
///
/// 后续各格式代理会用真实渲染器整文件替换 handler 实现；
/// 本类保持契约（[BookRenderer]/[ReaderController]）的最小可用实现，
/// 也作为新格式 handler 的参考样例。
library;

import 'package:flutter/material.dart';

import 'contract/book_renderer.dart';
import 'contract/progress_anchor.dart';
import 'contract/reader_controller.dart';
import 'contract/toc_entry.dart';

/// 占位控制器：恢复/上报/跳转均为空实现。
///
/// onProgressChanged 继承自 [ReaderController] 的实例字段，直接赋值即可。
class StubReaderController extends ReaderController {
  @override
  Future<ReaderRestoreResult> restore(ProgressAnchor saved) async =>
      ReaderRestoreResult(
        mode: saved.hasProgress
            ? ReaderRestoreMode.degradedToPercent
            : ReaderRestoreMode.noProgress,
        applied: ProgressAnchor.empty,
      );

  @override
  ProgressAnchor get currentLocator => ProgressAnchor.empty;

  @override
  double get percent => 0;

  @override
  Future<void> jumpTo(TocEntry entry) async {}

  @override
  Future<bool> nextPage() async => false; // 占位：无可翻内容

  @override
  Future<bool> previousPage() async => false; // 占位：无可翻内容

  @override
  void dispose() {}
}

/// 占位渲染器：显示"该格式渲染器将在后续集成"提示页。
class StubRenderer extends BookRenderer {
  /// 创建（[formatId] 用于展示说明）。
  StubRenderer({required this.formatId});

  /// 渲染器对应的格式标识。
  final String formatId;

  @override
  final StubReaderController controller = StubReaderController();

  @override
  Widget buildView(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.auto_stories_outlined,
          size: 56,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 16),
        Text('「$formatId」渲染器将在后续集成'),
        const SizedBox(height: 8),
        Text(
          '书籍导入与目录解析已就绪，排版与进度管线由各格式代理实现',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  @override
  void dispose() => controller.dispose();
}
