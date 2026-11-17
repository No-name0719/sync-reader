/// 阅读正文滚动物理（滚动模式甩动封顶）测试。
///
/// 用户实测：「移动端滚动分页直接滑动会一次性滚动很多，需要按住屏幕滑动
/// 才能控制」——平台默认的惯性滚动在手机上甩一下能滑出好几屏。
///
/// 修法：[ReaderScrollPhysics] 把**甩动速度**封顶（平台仿真模型不变，
/// 只是甩不远），位移上限 = 视口高 × [ReaderScrollPhysics.maxFlingScreens]。
///
/// 契约：
/// 1. 速度未超上限 → 原样返回（不改变平台手感）；
/// 2. 速度超上限 → 封顶且**方向不变**；
/// 3. **实测**甩动位移 ≤ 上限（真跑一次甩动，量位移——公式与平台常量
///    耦合，平台模型若变，此用例即红）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/reader_scroll_physics.dart';

void main() {
  group('速度封顶（纯函数）', () {
    test('未超上限的速度原样返回', () {
      const maxDistance = 1000.0;
      final capped = ReaderScrollPhysics.capFlingVelocity(
        100,
        maxDistance: maxDistance,
      );
      expect(capped, 100.0);
    });

    test('超上限的速度被封顶且方向不变', () {
      const maxDistance = 1000.0;
      final capped = ReaderScrollPhysics.capFlingVelocity(
        20000,
        maxDistance: maxDistance,
      );
      expect(capped, lessThan(20000.0));
      expect(capped, greaterThan(0.0), reason: '方向不变');
      final back = ReaderScrollPhysics.capFlingVelocity(
        -20000,
        maxDistance: maxDistance,
      );
      expect(back, lessThan(0.0), reason: '反向甩动方向不变');
      expect(back.abs(), capped.abs(), reason: '正反向同幅');
    });

    test('上限为 0 时速度归零（不允许甩）', () {
      expect(ReaderScrollPhysics.capFlingVelocity(3000, maxDistance: 0), 0.0);
    });

    test('上限越大，允许的甩动速度越大（单调）', () {
      final small = ReaderScrollPhysics.capFlingVelocity(
        5000,
        maxDistance: 500,
      );
      final large = ReaderScrollPhysics.capFlingVelocity(
        5000,
        maxDistance: 5000,
      );
      expect(large, greaterThan(small));
      expect(large, 5000.0, reason: '大上限下不封顶');
    });
  });

  group('实测甩动位移（widget）', () {
    /// 挂一个可滚动的列表，返回滚动控制器。
    Future<ScrollController> pumpList(
      WidgetTester tester, {
      required bool capped,
    }) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ListView.builder(
            controller: controller,
            physics: capped
                ? const ReaderScrollPhysics()
                : const ClampingScrollPhysics(),
            itemCount: 200,
            itemBuilder: (context, index) =>
                SizedBox(height: 50, child: Text('$index')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('封顶物理：一次重甩位移 ≤ 手指位移 + 1.2 屏', (tester) async {
      final controller = await pumpList(tester, capped: true);
      final viewport = controller.position.viewportDimension;
      const finger = 120.0;
      await tester.fling(find.byType(ListView), const Offset(0, -finger), 8000);
      await tester.pumpAndSettle();
      final distance = controller.offset;
      expect(
        distance,
        lessThanOrEqualTo(finger + viewport * 1.2 + 24),
        reason:
            '甩动位移必须封顶（实测 $distance；上限 = 手指位移 $finger '
            '+ 1.2 屏 ${viewport * 1.2}，另留触摸余量）',
      );
    });

    testWidgets('对照：平台默认物理的重甩位移远大于上限', (tester) async {
      final controller = await pumpList(tester, capped: false);
      final viewport = controller.position.viewportDimension;
      await tester.fling(find.byType(ListView), const Offset(0, -120), 8000);
      await tester.pumpAndSettle();
      final distance = controller.offset;
      expect(
        distance,
        greaterThan(viewport * 1.2),
        reason:
            '平台默认物理确实会甩很远（实测 $distance）——'
            '这正是用户反馈的问题',
      );
    });
  });
}
