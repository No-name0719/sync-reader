/// 封面组件单测（lib/shared/cover_view.dart）：哈希取色稳定性 + 文字封面渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/shared/cover_view.dart';

void main() {
  group('coverColorFromHash', () {
    test('同一本书颜色稳定', () {
      final a = coverColorFromHash('sha256:deadbeef01020304');
      expect(coverColorFromHash('sha256:deadbeef01020304'), a);
    });

    test('不同哈希不同色相', () {
      expect(
        coverColorFromHash('sha256:0000000000000000'),
        isNot(coverColorFromHash('sha256:ffffffffffffffff')),
      );
    });

    test('柔和色：亮度偏高（可作底色）', () {
      final hsl = HSLColor.fromColor(coverColorFromHash('sha256:ab'));
      expect(hsl.lightness, greaterThan(0.6));
      expect(hsl.saturation, lessThan(0.6));
    });

    test('非法输入回落稳定', () {
      expect(coverColorFromHash(''), coverColorFromHash(''));
      expect(coverColorFromHash('no-prefix'), coverColorFromHash('no-prefix'));
    });
  });

  group('leadingGlyphs', () {
    test('取前两个字素', () {
      expect(leadingGlyphs('三体'), '三体');
      expect(leadingGlyphs('诛仙'), '诛仙');
      expect(leadingGlyphs('A long title'), 'A ');
      expect(leadingGlyphs('a👍b'), 'a👍'); // 代理对字素
    });
    test('空书名回落"书"', () => expect(leadingGlyphs('  '), '书'));
  });

  group('CoverView', () {
    Future<void> pumpCover(
      WidgetTester tester, {
      String? coverPath,
      String title = '三体',
      String author = '刘慈欣',
      String hash = 'sha256:deadbeef01020304',
    }) {
      return tester.pumpWidget(
        MaterialApp(
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

    testWidgets('无封面 → 文字封面（大字 + 书名 + 作者）', (tester) async {
      await pumpCover(tester);
      expect(find.text('三体'), findsNWidgets(2)); // 封面大字 + 书名小字
      expect(find.text('刘慈欣'), findsOneWidget);
    });

    testWidgets('无作者时只显示书名', (tester) async {
      await pumpCover(tester, author: '');
      expect(find.text('刘慈欣'), findsNothing);
    });

    testWidgets('封面文件缺失 → 不崩溃（回落占位）', (tester) async {
      await pumpCover(tester, coverPath: '/nonexistent/cover.png');
      await tester.pump(const Duration(milliseconds: 50));
      // fakeAsync 下图片加载不会完成/报错，不应有异常抛出。
      expect(tester.takeException(), isNull);
    });
  });
}
