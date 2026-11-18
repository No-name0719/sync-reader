/// UI 字体栈测试（docs/10 §3.2 / §9.16）。
///
/// 背景：UI 字体族此前硬写 'Roboto'——Android 原生有，Windows **不装**，
/// 引擎回退平台默认字体（Segoe UI）后中文又落到 DirectWrite 的系统回退链，
/// 得到一支与拉丁不同源、且不认 w600 字重的怪字体（中英混排像两种字体）。
/// 修法：字体族按平台解析 + CJK 走显式回退栈。
///
/// 断言口径：
/// - 每个平台都必须解析出**该平台真实存在**的字体族（不许再出现 'Roboto' 这种
///   只在 Android 存在的族）；
/// - 汉字必须有显式回退族（不许依赖引擎的系统回退）；
/// - 字阶与 ThemeData 都必须带上族 + 回退栈（否则控件各写各的）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('AppFonts.ui 按平台解析', () {
    test('Windows：拉丁走 Segoe UI，汉字回退微软雅黑', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(AppFonts.ui, 'Segoe UI');
      expect(AppFonts.uiFallback, contains('Microsoft YaHei'));
    });

    test('Android：拉丁走 Roboto（原生），汉字回退思源黑体', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(AppFonts.ui, 'Roboto');
      expect(AppFonts.uiFallback, contains('Noto Sans SC'));
    });

    test('macOS/iOS：拉丁走 Helvetica Neue，汉字回退苹方', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(AppFonts.ui, 'Helvetica Neue', reason: '$platform');
        expect(
          AppFonts.uiFallback,
          contains('PingFang SC'),
          reason: '$platform',
        );
      }
    });

    test('Linux：拉丁走 Noto Sans，汉字回退思源黑体', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(AppFonts.ui, 'Noto Sans');
      expect(AppFonts.uiFallback, contains('Noto Sans CJK SC'));
    });

    test('任何平台都不许把 UI 字体族解析成只在 Android 存在的 Roboto', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        if (platform == TargetPlatform.android) {
          expect(AppFonts.ui, 'Roboto', reason: '$platform');
        } else {
          expect(AppFonts.ui, isNot('Roboto'), reason: '$platform');
        }
      }
    });

    test('每个平台的 CJK 回退栈都非空（不许交给引擎的系统回退）', () {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        expect(AppFonts.uiFallback, isNotEmpty, reason: '$platform');
      }
    });
  });

  group('字阶与主题都带上字体族', () {
    test('所有字阶样式都带 fontFamily 与 fontFamilyFallback', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final tokens = AppDesignTokens.light(AppAccent.terracotta);
      final styles = <TextStyle>[
        tokens.display,
        tokens.h1,
        tokens.h2,
        tokens.h3,
        tokens.body,
        tokens.sm,
        tokens.caption,
        tokens.micro,
        tokens.tertiary,
      ];
      for (final style in styles) {
        expect(style.fontFamily, AppFonts.ui);
        expect(style.fontFamilyFallback, AppFonts.uiFallback);
      }
    });

    test('ThemeData 自身也带字体族（Material 自拼的字也走同一套）', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final theme = AppTheme.light(AppAccent.terracotta);
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Segoe UI');
      expect(theme.textTheme.titleLarge?.fontFamily, 'Segoe UI');
    });
  });
}
