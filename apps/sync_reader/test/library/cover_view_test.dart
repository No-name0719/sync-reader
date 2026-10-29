/// 封面组件单测（lib/shared/cover_view.dart）：纸底墨字取色稳定性/明暗
/// 两套取值范围 + 生成封面渲染（A17/Q8）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/shared/cover_view.dart';

void main() {
  group('paperPaletteFromHash', () {
    test('同一本书颜色稳定（跨端重启不变）', () {
      final a = paperPaletteFromHash('sha256:deadbeef01020304', dark: false);
      expect(paperPaletteFromHash('sha256:deadbeef01020304', dark: false), a);
      final d = paperPaletteFromHash('sha256:deadbeef01020304', dark: true);
      expect(paperPaletteFromHash('sha256:deadbeef01020304', dark: true), d);
    });

    test('不同哈希不同色相', () {
      expect(
        paperPaletteFromHash('sha256:0000000000000000', dark: false),
        isNot(paperPaletteFromHash('sha256:ffffffffffffffff', dark: false)),
      );
    });

    test('浅色纸底：极低饱和 + 高亮（hsl(h 12% 90%)），墨色为同色系深色', () {
      final palette = paperPaletteFromHash('sha256:ab12cd34', dark: false);
      final bg = HSLColor.fromColor(palette.background);
      final ink = HSLColor.fromColor(palette.ink);
      // HSL 往返有取整误差，给 0.02 容差。
      expect(bg.saturation, inInclusiveRange(0.10, 0.14), reason: '纸底饱和度约 12%');
      expect(bg.lightness, inInclusiveRange(0.88, 0.92), reason: '纸底亮度约 90%');
      expect(ink.lightness, lessThan(0.30), reason: '墨色为深墨');
      expect(ink.saturation, lessThan(0.25), reason: '墨色同为低饱和');
    });

    test('深色：深纸底 + 浅墨，仍可读', () {
      final palette = paperPaletteFromHash('sha256:ab12cd34', dark: true);
      final bg = HSLColor.fromColor(palette.background);
      final ink = HSLColor.fromColor(palette.ink);
      expect(bg.lightness, inInclusiveRange(0.14, 0.18), reason: '深纸底');
      expect(ink.lightness, greaterThan(0.80), reason: '浅墨');
      expect(ink.saturation, lessThan(0.25));
    });

    test('非法输入回落稳定', () {
      expect(
        paperPaletteFromHash('', dark: false),
        paperPaletteFromHash('', dark: false),
      );
      expect(
        paperPaletteFromHash('no-prefix', dark: false),
        paperPaletteFromHash('no-prefix', dark: false),
      );
    });
  });

  group('leadingGlyphs', () {
    test('取首字素（纸底封面大字）', () {
      expect(leadingGlyphs('三体'), '三');
      expect(leadingGlyphs('a👍b'), 'a'); // 代理对字素
      expect(leadingGlyphs('三体', count: 2), '三体');
    });
    test('空书名回落"书"', () => expect(leadingGlyphs('  '), '书'));
  });

  group('CoverView（纸底墨字 fallback）', () {
    Future<void> pumpCover(
      WidgetTester tester, {
      String? coverPath,
      String title = '三体',
      String author = '刘慈欣',
      String hash = 'sha256:deadbeef01020304',
      bool dark = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          theme: dark
              ? AppTheme.dark(AppAccent.terracotta)
              : AppTheme.light(AppAccent.terracotta),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 100,
                height: 150,
                child: CoverView(
                  coverPath: coverPath,
                  title: title,
                  author: author,
                  contentHash: hash,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('无封面 → 纸底墨字（首字大字 + 书名 + 作者）', (tester) async {
      await pumpCover(tester);
      expect(find.text('三'), findsOneWidget); // 首字大字
      expect(find.text('三体'), findsOneWidget); // 书名小字
      expect(find.text('刘慈欣'), findsOneWidget);
    });

    testWidgets('无作者时只显示书名', (tester) async {
      await pumpCover(tester, author: '');
      expect(find.text('刘慈欣'), findsNothing);
    });

    testWidgets('封面文件缺失 → 不崩溃（回落纸底墨字）', (tester) async {
      await pumpCover(tester, coverPath: '/nonexistent/cover.png');
      await tester.pump(const Duration(milliseconds: 50));
      // fakeAsync 下图片加载不会完成/报错，不应有异常抛出。
      expect(tester.takeException(), isNull);
    });

    testWidgets('深色主题下渲染不崩溃', (tester) async {
      await pumpCover(tester, dark: true);
      expect(find.text('三'), findsOneWidget);
    });
  });
}
