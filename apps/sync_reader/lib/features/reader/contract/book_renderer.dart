/// 阅读渲染器抽象（冻结 API，docs/03 §4.2）。
library;

import 'package:flutter/widgets.dart';

import 'reader_controller.dart';

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
}
