/// 图标与文字的**光学对齐**基建（跨页面复用）。
///
/// ## 痛点
///
/// Flutter 的 `Text` 占位的是**行盒**（字号 × 行高倍数），不是字面高度；
/// 而 `Icon(size: n)` 占的是 n×n 的正方形盒。两者并排放在
/// `Row(crossAxisAlignment: CrossAxisAlignment.start)` 里时：
///
/// - 行盒高度（body 14×22 = **22**）与图标盒（18）不等高 → 图标中心比首行
///   文字中心高 2px，看着「图标和字没对齐」（用户实测：桌面端与移动端都
///   有，设置页「存储」四行最明显）；
/// - 图标盒比行盒**高**时（圆角徽标块 26 vs 22）则相反，块心偏低。
library;

import 'package:flutter/material.dart';

/// 文字样式的**行盒高度**（逻辑像素）。
///
/// Flutter 的 [TextStyle.height] 是「行高倍数」，行盒高 = 字号 × 倍数。
/// 行盒才是文字真正的占位高度——图标按它对齐才不会错位。
///
/// [style] 缺 `fontSize`/`height` 时退回 [fallback]（本项目所有字阶都带
/// 两者，见 `core/design_tokens.dart` 的 [AppTextScale]）。
double textLineHeight(TextStyle style, {double fallback = 20}) {
  final size = style.fontSize;
  final height = style.height;
  if (size == null || height == null) return fallback;
  return size * height;
}

/// 把一个图标（或图标徽标块）按**首行文字的光学中心**对齐。
///
/// 做法：给图标一个与**首行行盒等高**的盒子并在盒内居中——图标中心与首行
/// 文字中心落在同一条水平线上。
///
/// 图标本体比行盒高时（圆角徽标块），把块**向上提半格差**，使块心对到行盒
/// 中心（否则顶对齐时块心偏低，看着没对齐）。
///
/// 配套用法：
/// ```dart
/// Row(
///   crossAxisAlignment: CrossAxisAlignment.start,
///   children: [
///     IconLineSlot(
///       lineHeight: textLineHeight(t.body),
///       child: Icon(Icons.description_outlined, size: 18),
///     ),
///     const SizedBox(width: AppSpacing.s3),
///     Expanded(child: Text('正文', style: t.body)),
///   ],
/// )
/// ```
class IconLineSlot extends StatelessWidget {
  const IconLineSlot({
    super.key,
    required this.child,
    required this.lineHeight,
    this.childSize,
  });

  /// 图标（或徽标块）本体：按自身尺寸绘制，不被行盒压扁。
  final Widget child;

  /// 首行文字的行盒高度（逻辑像素）。
  final double lineHeight;

  /// 图标本体的边长：徽标块比行盒高时用它算上提量；不传则视为不高于行盒。
  final double? childSize;

  @override
  Widget build(BuildContext context) {
    final size = childSize ?? lineHeight;
    final over = size - lineHeight;
    if (over <= 0) {
      // 图标不高于行盒：放进**等高槽位**居中 → 两者中心重合。
      return SizedBox(
        height: lineHeight,
        child: Align(alignment: Alignment.center, child: child),
      );
    }
    // 徽标块高于行盒：保持自身尺寸（不被行盒压扁），整体**上提半格差**，
    // 使块心与行盒中心重合。
    return Transform.translate(offset: Offset(0, -over / 2), child: child);
  }
}
