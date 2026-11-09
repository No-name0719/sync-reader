/// TxtRenderer 视图冒烟测试：page/scroll 双模式 buildView 可渲染出章首内容
/// （排版计算用 debugSyncPagination 同步化以适配 FakeAsync）。
/// v1.1：渲染器内置页脚已移除（页码/进度由宿主底部控制条承载，A8），
/// 正文段落带 2em 首行缩进并两端对齐（A10）。
/// v1.2：page 模式 PageView 轴向随翻页动画设置切换（B5），正文渲染用
/// 页显示文本（页尾分页符不产生空行盒，B1）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    // A10：正文显示文本带 2em 全角空格缩进（分页器与视图共用同一变换）。
    final pageText = tester.widget<Text>(
      find
          .descendant(of: find.byType(PageView), matching: find.byType(Text))
          .first,
    );
    expect(
      (pageText.data ?? '').startsWith(kReaderParagraphIndent),
      isTrue,
      reason: '页首段落带 2em 首行缩进',
    );
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

  group('v1.2 B5 翻页动画轴向', () {
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

    testWidgets('出厂默认（上下滑动）→ PageView 纵轴', (tester) async {
      final renderer = await pumpPageMode(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      final scrollable = tester.widget<Scrollable>(
        find.descendant(of: pageViewFinder(), matching: find.byType(Scrollable)),
      );
      expect(scrollable.axis, Axis.vertical, reason: 'B5：上下滑动为默认');
      renderer.dispose();
    });

    testWidgets('左右翻页设置 → PageView 横轴', (tester) async {
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
      expect(scrollable.axis, Axis.horizontal, reason: 'B5：左右翻页切横轴');
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
