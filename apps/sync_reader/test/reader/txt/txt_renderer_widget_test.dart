/// TxtRenderer 视图冒烟测试：page/scroll 双模式 buildView 可渲染出章首内容
/// （排版计算用 debugSyncPagination 同步化以适配 FakeAsync）。
/// v1.1：渲染器内置页脚已移除（页码/进度由宿主底部控制条承载，A8），
/// 正文段落带 2em 首行缩进并两端对齐（A10）。
/// v1.2：page 模式 PageView 轴向随翻页方向切换（B5；v1.3.7 起方向固定
/// 左右，UI 只提供「滚动（上下）/ 分页（左右）」两种方式），正文渲染用
/// 页显示文本（页尾分页符不产生空行盒，B1）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';

/// 章内容足够长：确保末章远超 ListView cacheExtent，惰性断言稳定。
final String bookText =
    '第一章 开端\n${'甲' * 2000}\n'
    '第二章 发展\n${'乙' * 2000}\n'
    '第三章 结局\n${'丙' * 2000}\n';

Future<BookFile> _writeBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_widget');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}冒烟书.txt');
  await file.writeAsBytes(Uint8List.fromList(utf8.encode(bookText)));
  return BookFile.fromPath(file.path);
}

void main() {
  setUpAll(() {
    // FakeAsync 环境（isolate 消息不可达）：分页同步化，保证面板可完成加载。
    TxtPaginator.debugSyncPagination = true;
  });

  tearDownAll(() {
    TxtPaginator.debugSyncPagination = false;
  });

  testWidgets('page 模式：渲染章首页文本（含 2em 缩进），无内置页脚', (tester) async {
    final bf = (await tester.runAsync(_writeBook))!;
    final renderer =
        (await tester.runAsync(
              () => TxtFormatHandler().createRenderer(
                bf,
                ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
                ProgressAnchor.empty,
              ),
            ))!
            as TxtRenderer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    expect(find.textContaining('第一章 开端'), findsWidgets, reason: '首屏页含章首内容');
    // A10：正文段首缩进是**行内占位符**（宽 2em；空白字符会被两端对齐吞掉），
    // 分页器与视图共用同一变换。
    final pageText = tester.widget<Text>(
      find
          .descendant(of: find.byType(PageView), matching: find.byType(Text))
          .first,
    );
    var indentCount = 0;
    pageText.textSpan?.visitChildren((child) {
      if (child is WidgetSpan) indentCount++;
      return true;
    });
    expect(indentCount, greaterThan(0), reason: '页首段落带 2em 首行缩进占位符');
    expect(pageText.textAlign, TextAlign.justify, reason: 'A10 两端对齐');
    // A8：页脚移除，页码信息经 currentPageInfo 能力供宿主控制条。
    expect(renderer.currentPageInfo, isNotNull);

    renderer.dispose();
  });

  testWidgets('scroll 模式：按章分块渲染，视口外末章不构建（惰性）', (tester) async {
    final bf = (await tester.runAsync(_writeBook))!;
    final renderer = (await tester.runAsync(
      () => TxtFormatHandler().createRenderer(
        bf,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.scroll),
        ProgressAnchor.empty,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.textContaining('第一章 开端'), findsWidgets, reason: '首章章题可见');
    expect(
      find.textContaining('第三章'),
      findsNothing,
      reason: '惰性构建：远超 cacheExtent 的末章不立即构建',
    );

    renderer.dispose();
  });

  group('翻页方向轴向（v1.3.7：按设备形态自动选）', () {
    Future<TxtRenderer> pumpPageMode(
      WidgetTester tester,
      ReaderSettings settings,
    ) async {
      final bf = (await tester.runAsync(_writeBook))!;
      final renderer = (await tester.runAsync(
        () => TxtFormatHandler().createRenderer(bf, settings, ProgressAnchor.empty),
      ))!
          as TxtRenderer;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => renderer.buildView(context)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return renderer;
    }

    Finder pageViewFinder() => find.descendant(
      of: find.byType(Scaffold),
      matching: find.byType(PageView),
    );

    testWidgets('桌面视口（宽）→ PageView 纵轴（与滚轮/鼠标拖拽同向）', (
      tester,
    ) async {
      // v1.3.7：翻页方向不再是用户选项，按**设备形态**自动选——
      // 电脑端用纵轴（鼠标滚轮与按住拖拽都是纵向的）。
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(of: pageViewFinder(), matching: find.byType(Scrollable)),
      );
      expect(scrollable.axis, Axis.vertical, reason: '电脑端分页 = 上下拖拽翻页');
      renderer.dispose();
    });

    testWidgets('手机视口（窄 ≤460）→ PageView 横轴（左右翻页手感）', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(of: pageViewFinder(), matching: find.byType(Scrollable)),
      );
      expect(scrollable.axis, Axis.horizontal, reason: '手机端分页 = 左右翻页');
      renderer.dispose();
    });

    testWidgets('持久化的翻页方向不再被采纳（方向按设备形态自动选）', (
      tester,
    ) async {
      // v1.3.7：翻页方向从「用户选项」降级为「设备形态决定」，持久化里的
      // 旧值（horizontal/vertical）一律不采纳——桌面视口下恒为纵轴。
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.page,
          pageTurnAxis: ReaderPageTurnAxis.horizontal,
        ),
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(of: pageViewFinder(), matching: find.byType(Scrollable)),
      );
      expect(scrollable.axis, Axis.vertical, reason: '桌面视口恒为纵轴');
      renderer.dispose();
    });

    testWidgets('v1.3.7：分页模式滚轮无效（只由键盘/触摸滑动翻页）', (
      tester,
    ) async {
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      /// PageView 的滚动偏移（分页位置；null = 尚未挂载）。
      double? pageOffset() {
        final scrollable = tester.widget<Scrollable>(
          find.descendant(
            of: pageViewFinder(),
            matching: find.byType(Scrollable),
          ),
        );
        final controller = scrollable.controller;
        if (controller == null || !controller.hasClients) return null;
        return controller.position.pixels;
      }

      final before = pageOffset();

      // 滚一格（纵向 100 = Windows 一档）：分页模式下不得翻页、也不得滚动。
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 300),
          scrollDelta: Offset(0, 100),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        pageOffset(),
        before,
        reason: '滚轮不得驱动 PageView 翻页（分页模式只认键盘与触摸滑动）',
      );
      renderer.dispose();
    });

    testWidgets('v1.3.7：分页模式鼠标拖动不翻页（触摸滑动仍可）', (
      tester,
    ) async {
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );

      /// PageView 的滚动偏移（分页位置）。
      double? pageOffset() {
        final scrollable = tester.widget<Scrollable>(
          find.descendant(
            of: pageViewFinder(),
            matching: find.byType(Scrollable),
          ),
        );
        final controller = scrollable.controller;
        if (controller == null || !controller.hasClients) return null;
        return controller.position.pixels;
      }

      final before = pageOffset();

      // 鼠标拖动：分页模式不得被拖动翻页。
      // 滑动幅度须超过半页（PageView 的翻页阈值 ≈ 284px），否则会被吸附回去。
      final mouse = await tester.startGesture(
        const Offset(200, 400),
        kind: PointerDeviceKind.mouse,
      );
      await mouse.moveBy(const Offset(0, -400));
      await mouse.up();
      await tester.pumpAndSettle();
      expect(
        pageOffset(),
        before,
        reason: '分页模式不得用鼠标拖动翻页（只用键盘与触摸滑动）',
      );

      // 触摸滑动仍可翻页（手机端主交互不能被误伤）。
      final touch = await tester.startGesture(
        const Offset(200, 400),
        kind: PointerDeviceKind.touch,
      );
      await touch.moveBy(const Offset(0, -400));
      await touch.up();
      await tester.pumpAndSettle();
      expect(
        pageOffset(),
        isNot(before),
        reason: '触摸滑动仍应能翻页',
      );
      renderer.dispose();
    });

    testWidgets('整行分页（B1）：单页正文渲染高度不超过内容区（页尾留白不切字）',
        (tester) async {
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      // 首页正文的渲染盒高度 ≤ 视口可用高度（列宽 720 上限之外，测试
      // 默认面 800×600：内容高 = 600 − 2×16 边距 = 568）。
      final pageText = tester.renderObject<RenderParagraph>(
        find
            .descendant(of: pageViewFinder(), matching: find.byType(Text))
            .first,
      );
      expect(
        pageText.size.height,
        lessThanOrEqualTo(600 - 16 * 2 + 0.5),
        reason: 'B1 整行分页：页内容不溢出视口',
      );
      renderer.dispose();
    });
  });
}
