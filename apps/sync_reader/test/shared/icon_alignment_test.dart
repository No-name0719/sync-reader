/// 图标与文字的光学对齐（v1.4.6，用户实测：「双端都存在图标和文字不对齐
/// 的情况」）。
///
/// 缺陷背景：Flutter 的 `Text` 占位的是**行盒**（字号 × 行高倍数），而
/// `Icon(size: n)` 占的是 n×n 正方形盒。把图标直接放进
/// `Row(crossAxisAlignment: CrossAxisAlignment.start)` 时，图标盒（18）与
/// 首行文字的行盒（body 14×22 = 22）不等高 → 图标中心比文字中心高 2px，
/// 看着「图标和字没对齐」。
///
/// 本测试钉死：
/// 1. [textLineHeight] 按「字号 × 行高倍数」算行盒（缺值时退回兜底）；
/// 2. [IconLineSlot] 把图标放进**等高行盒**里居中 → 图标中心 == 行盒中心；
/// 3. 图标比行盒高时（圆角徽标块）块心被提到行盒中心。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/shared/icon_alignment.dart';

void main() {
  group('textLineHeight', () {
    test('行盒高 = 字号 × 行高倍数', () {
      expect(
        textLineHeight(const TextStyle(fontSize: 14, height: 22 / 14)),
        closeTo(22, 0.001),
      );
      expect(
        textLineHeight(const TextStyle(fontSize: 13, height: 20 / 13)),
        closeTo(20, 0.001),
      );
      expect(
        textLineHeight(const TextStyle(fontSize: 12, height: 18 / 12)),
        closeTo(18, 0.001),
      );
    });

    test('缺 fontSize / height 时退回兜底值', () {
      expect(textLineHeight(const TextStyle()), 20);
      expect(textLineHeight(const TextStyle(fontSize: 14), fallback: 24), 24);
      expect(textLineHeight(const TextStyle(height: 1.5), fallback: 18), 18);
    });
  });

  group('IconLineSlot', () {
    testWidgets('图标中心 == 首行文字行盒中心', (tester) async {
      const lineHeight = 22.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconLineSlot(
                  lineHeight: lineHeight,
                  child: Icon(Icons.description_outlined, size: 18),
                ),
                Text('正文', style: TextStyle(fontSize: 14, height: 22 / 14)),
              ],
            ),
          ),
        ),
      );

      final iconRect = tester.getRect(find.byIcon(Icons.description_outlined));
      final textRect = tester.getRect(find.text('正文'));

      // 图标盒（18）比文字行盒（22）矮 → 旧实现顶对齐时图标中心高出 2px。
      expect(
        (iconRect.center.dy - textRect.center.dy).abs(),
        lessThan(0.01),
        reason:
            '图标中心必须与首行文字行盒中心重合（实测偏差 '
            '${iconRect.center.dy - textRect.center.dy}）',
      );
      // 文字行盒本身仍是 22 高（不被压缩）。
      expect(textRect.height, closeTo(lineHeight, 0.01));
    });

    testWidgets('徽标块比行盒高时：块心被提到行盒中心', (tester) async {
      const lineHeight = 22.0;
      const badge = 26.0;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconLineSlot(
                  lineHeight: lineHeight,
                  childSize: badge,
                  child: SizedBox(
                    width: badge,
                    height: badge,
                    child: Icon(Icons.check, size: 15),
                  ),
                ),
                Text('正文', style: TextStyle(fontSize: 14, height: 22 / 14)),
              ],
            ),
          ),
        ),
      );

      final badgeRect = tester.getRect(find.byIcon(Icons.check));
      final textRect = tester.getRect(find.text('正文'));
      expect(
        (badgeRect.center.dy - textRect.center.dy).abs(),
        lessThan(0.01),
        reason: '徽标块中心必须与首行文字行盒中心重合',
      );
    });

    testWidgets('行盒高度固定：图标尺寸变化不改变槽位高度', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconLineSlot(lineHeight: 22, child: Icon(Icons.add, size: 16)),
                SizedBox(
                  height: 22,
                  child: Text(
                    '导入',
                    style: TextStyle(fontSize: 13, height: 20 / 13),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      final iconRect = tester.getRect(find.byIcon(Icons.add));
      expect(iconRect.height, closeTo(16, 0.01));
      // 图标在 22 高的槽位里居中：上留白 (22-16)/2 = 3。
      expect(iconRect.top, closeTo(3, 0.01), reason: '图标应在等高槽位内居中');
    });
  });
}
