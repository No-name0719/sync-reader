/// 阅读页整屏亮度滤镜（v1.2 B3）。
///
/// 夜间系阅读背景下的亮度系数作用在**整屏**上（背景与正文一起变暗/变亮，
/// 对齐原型 `.rd { filter: brightness(var(--rd-bright)) }`），不是只调文字；
/// 80% 下限保证正文对比度仍达 AAA（对比度门测试锁定）。渲染端用
/// `ColorFiltered` 亮度矩阵实现，与测试端 `scaleColorBrightness` 同口径
/// （sRGB 通道线性缩放）。
library;

import 'package:flutter/material.dart';

/// 整屏亮度滤镜：非夜间系或系数为 1.0 时原样返回 [child]。
class ReaderBrightnessFilter extends StatelessWidget {
  const ReaderBrightnessFilter({
    super.key,
    required this.isNightTheme,
    required this.brightness,
    required this.child,
  });

  /// 当前阅读主题是否为夜间系（B3：滤镜只在夜间系背景生效）。
  final bool isNightTheme;

  /// 亮度系数（0.8–1.3；1.0 = 不变）。
  final double brightness;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isNightTheme || (brightness - 1.0).abs() < 0.001) return child;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(<double>[
        brightness, 0, 0, 0, 0, //
        0, brightness, 0, 0, 0, //
        0, 0, brightness, 0, 0, //
        0, 0, 0, 1, 0,
      ]),
      child: child,
    );
  }
}
