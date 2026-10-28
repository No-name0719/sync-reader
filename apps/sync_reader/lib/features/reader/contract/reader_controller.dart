/// 阅读器控制器抽象（冻结 API，docs/03 §4.2）：渲染器暴露给宿主的唯一交互面。
///
/// 进度管线约定（完整管线由后续集成代理接线）：
/// - 渲染器内部对翻页/滚动做**节流（防抖 3s，docs/03 §3.1）**后调用
///   [onProgressChanged]，宿主负责落库（progress 表，dirty=true）；
/// - [restore] 按 docs/05 §3.3 规则恢复：指纹一致精确恢复，否则 percent 降级，
///   并通过返回值告知宿主实际恢复方式。
library;

import 'progress_anchor.dart';
import 'toc_entry.dart';

/// 进度变化回调：翻页/滚动节流后由渲染器调用（切后台/退出时宿主还应主动
/// 读取一次 [currentLocator]/[percent] 兜底落库，FR-207）。
typedef ReaderProgressCallback = void Function(
  ProgressAnchor locator,
  double percent,
);

/// 阅读器控制器。
abstract class ReaderController {
  /// 进度变化回调（节流后触发；null = 不上报）。
  ReaderProgressCallback? onProgressChanged;

  /// 恢复到已保存进度（docs/05 §3.3 规则），返回实际恢复方式。
  Future<ReaderRestoreResult> restore(ProgressAnchor saved);

  /// 当前逻辑位置（locator JSON + percent）。
  ProgressAnchor get currentLocator;

  /// 当前全书阅读比例 0.0–1.0。
  double get percent;

  /// 跳转到目录条目（书内跳转）。
  Future<void> jumpTo(TocEntry entry);

  /// 翻到下一页：分页模式翻一页；滚动模式滚动一屏。
  /// 返回是否发生实际移动（已在边界为 false，供音量键翻页与测试断言）。
  Future<bool> nextPage();

  /// 翻到上一页：语义同 [nextPage]，方向相反。
  Future<bool> previousPage();

  /// 释放资源（停计时器、关流；宿主在页面 dispose 时调用）。
  void dispose();
}
