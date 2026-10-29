/// 阅读渲染器抽象（冻结 API，docs/03 §4.2）。
library;

import 'package:flutter/widgets.dart';

import 'reader_controller.dart';
import 'toc_entry.dart';

/// 某一格式在某本书上的渲染会话：视图 + 控制器成对出现。
///
/// 生命周期：[BookFormatHandler.createRenderer] 创建 → 宿主 build [buildView]
/// → 页面退出时 [dispose]（宿主保证先取走 [controller] 的最终进度再 dispose）。
abstract class BookRenderer {
  /// 阅读控制器（进度/跳转的唯一入口）。
  ReaderController get controller;

  /// 构建阅读视图（嵌入 ReaderPage 的 body）。
  Widget buildView(BuildContext context);

  /// 释放资源；调用后渲染器不可复用。
  void dispose();

  /// 目录条目是否正位于当前阅读位置（目录抽屉「当前」标记，docs/10 A8）。
  ///
  /// 契约外公开约定（与 applySettings 同级的能力扩展，v1.1 新增）：
  /// 各真实渲染器按自己的锚点类型比对当前位置，基类默认 false。
  bool isTocEntryCurrent(TocEntry entry) => false;
}

/// 页码信息能力（契约外公开约定，v1.1 A8 底部控制条用）。
///
/// 分页型渲染器（txt page 模式）提供当前章内页码；连续滚动型渲染器
/// 不实现该接口，宿主显示为纯百分比。
abstract interface class ReaderPageInfoProvider {
  /// (当前页 0 起, 页数)；页码不可用（未就绪/滚动模式）时 null。
  (int, int)? get currentPageInfo;
}

/// 按全书比例跳转能力（契约外公开约定，v1.1 A8 进度滑块用）。
abstract interface class ReaderPercentJump {
  /// 跳转到全书比例 [percent] ∈ [0,1]（滑块拖动结束时调用，天然节流）。
  /// 实现须可重入、不破坏既有进度坐标语义（只改视觉落点）。
  Future<void> jumpToPercent(double percent);
}
