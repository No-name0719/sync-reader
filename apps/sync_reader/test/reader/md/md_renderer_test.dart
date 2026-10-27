/// MdRenderer widget 测试（少量冒烟）：分块渲染、滚动 → locator 上报、
/// restore 三分支、jumpTo 锚点映射、applySettings 生效、占位渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/md/md_block_parser.dart';
import 'package:sync_reader/features/reader/formats/md/md_locator.dart';
import 'package:sync_reader/features/reader/formats/md/md_renderer.dart';
import 'package:sync_reader/features/reader/formats/md/md_style.dart';

/// 多章长文：chapters 个 `# 章节` + 每章 paras 个段落，保证溢出滚动。
String longDoc({int chapters = 6, int parasPerChapter = 30}) {
  final b = StringBuffer();
  for (var c = 0; c < chapters; c++) {
    b
      ..writeln('# 第$c章 标题行')
      ..writeln();
    for (var i = 0; i < parasPerChapter; i++) {
      b
        ..writeln('第$c章的第$i段内容，用于撑起足够的滚动高度，使滚动与定位可测。')
        ..writeln();
    }
  }
  return b.toString();
}

Future<void> pumpReader(WidgetTester tester, MdRenderer renderer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => renderer.buildView(context)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推进 FakeAsync 时钟越过 3s 节流窗口（含尾随补发的第二窗口），
/// 保证测试结束时不留悬挂 Timer（flutter_test invariant 检查）。
Future<void> drainProgressThrottle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  group('渲染', () {
    testWidgets('标题与段落按块渲染', (tester) async {
      const sample = '# 第一章\n\n开头段落。\n';
      final blocks = const MdBlockParser().parse(sample);
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: sample.length,
      );
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);
      expect(find.text('第一章'), findsOneWidget);
      expect(find.text('开头段落。'), findsOneWidget);
    });

    testWidgets('空文档渲染占位', (tester) async {
      final renderer = MdRenderer(blocks: const [], documentLength: 0);
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);
      expect(find.text('（空文档）'), findsOneWidget);
    });

    testWidgets('相对路径图片渲染占位（含 alt 文本）', (tester) async {
      const sample = '![本地图](./img/a.png)\n';
      final blocks = const MdBlockParser().parse(sample);
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: sample.length,
      );
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);
      expect(find.text('本地图'), findsOneWidget);
    });

    testWidgets('代码块横向滚动容器（FR-204 验收线：等宽字体样式由样式表保证）', (tester) async {
      const sample = '```\ncode line\n```\n';
      final blocks = const MdBlockParser().parse(sample);
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: sample.length,
      );
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);
      // pre 元素由 flutter_markdown_plus 内置横向 SingleChildScrollView 承载。
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scroll.scrollDirection, Axis.horizontal);
    });
  });

  group('滚动进度上报', () {
    testWidgets('滚到底 → 上报 type=md locator，percent 与 currentLocator 一致', (
      tester,
    ) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);

      final anchors = <ProgressAnchor>[];
      renderer.controller.onProgressChanged = (anchor, percent) {
        anchors.add(anchor);
      };

      await pumpReader(tester, renderer);
      expect(anchors, isEmpty);

      renderer.scrollController.jumpTo(
        renderer.scrollController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      // 程序化滚动只有一次位置事件且早于布局生效；帧末复测校正后
      // 推进时钟让节流尾随补发，anchors/currentLocator 才反映最终位置。
      await drainProgressThrottle(tester);

      expect(anchors, isNotEmpty);
      final last = anchors.last;
      final locator = last.decodeLocator()!;
      expect(locator['type'], 'md');
      expect(locator['blockIndex'], greaterThan(0));
      expect(locator['headingIndex'], 5); // 最后可见块之前最近的标题 = 第5章
      expect(renderer.controller.percent, greaterThan(0.5));
      expect(renderer.controller.currentLocator.locatorJson, last.locatorJson);
    });
  });

  group('restore 三分支', () {
    testWidgets('noProgress：无历史进度 → 留在开头', (tester) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);

      final future = renderer.controller.restore(ProgressAnchor.empty);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.noProgress);
      expect(result.applied, ProgressAnchor.empty);
      expect(renderer.controller.percent, 0);
      expect(
        renderer.controller.currentLocator.decodeLocator()!['blockIndex'],
        0,
      );
    });

    testWidgets('exact：locator 有效 → 滚到目标块（块顶对齐视口顶）', (tester) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      const targetBlock = 62; // 第 2 章标题块（每章 31 块）
      final anchor = ProgressAnchor(
        locatorJson: MdLocator.encode(
          headingIndex: 2,
          blockIndex: targetBlock,
          charOffset: blocks[targetBlock].sourceStart,
        ),
        percent: blocks[targetBlock].sourceStart / doc.length,
      );
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: doc.length,
        initialAnchor: anchor,
      );
      addTearDown(renderer.dispose);

      final future = renderer.controller.restore(anchor);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.exact);
      expect(result.applied.percent, anchor.percent);
      expect(
        renderer.controller.currentLocator.decodeLocator()!['blockIndex'],
        targetBlock,
      );
      await drainProgressThrottle(tester);
    });

    testWidgets('degraded：locator 解析失败 → percent 定位最近块，applied 落空对象', (
      tester,
    ) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final anchor = const ProgressAnchor(
        locatorJson: 'not-a-json{{',
        percent: 0.5,
      );
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);

      final future = renderer.controller.restore(anchor);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(result.applied.locatorJson, '{}');
      expect(result.applied.percent, 0.5);
      final expected = MdPositionMath.blockIndexForPercent(
        blocks,
        doc.length,
        0.5,
      );
      expect(
        renderer.controller.currentLocator.decodeLocator()!['blockIndex'],
        expected,
      );
      expect(expected, greaterThan(0));
      await drainProgressThrottle(tester);
    });

    testWidgets('degraded：blockIndex 越界同样降级', (tester) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final anchor = ProgressAnchor(
        locatorJson: MdLocator.encode(
          headingIndex: 0,
          blockIndex: 9999,
          charOffset: 0,
        ),
        percent: 0.9,
      );
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);

      final future = renderer.controller.restore(anchor);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(result.applied.percent, 0.9);
      await drainProgressThrottle(tester);
    });
  });

  group('jumpTo 与设置', () {
    testWidgets('jumpTo 目录条目 → 滚到对应标题块', (tester) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final toc = buildTocFromBlocks(blocks);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);

      await pumpReader(tester, renderer);
      // 先滚到底，再跳第 3 章标题。
      renderer.scrollController.jumpTo(
        renderer.scrollController.position.maxScrollExtent,
      );
      await tester.pumpAndSettle();
      await drainProgressThrottle(tester);

      // jumpTo 内部跨帧重试定位，须与 pumpAndSettle 并发推进（否则无帧可等）。
      final jumpFuture = renderer.controller.jumpTo(toc[3]);
      await tester.pumpAndSettle();
      await jumpFuture;

      final locator = renderer.controller.currentLocator.decodeLocator()!;
      expect(locator['blockIndex'], 3 * 31);
      expect(locator['headingIndex'], 3);
      expect(
        toc[3].anchor.toString(),
        'md:heading:3:${blocks[3 * 31].sourceStart}',
      );
      await drainProgressThrottle(tester);
    });

    testWidgets('applySettings 即时切换主题背景', (tester) async {
      const sample = '# 章题\n\n段落。\n';
      final blocks = const MdBlockParser().parse(sample);
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: sample.length,
      );
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final container = tester.widget<Container>(
        find.byKey(renderer.viewportKey),
      );
      expect(container.color, mdPaletteFor(ReaderTheme.light).background);

      renderer.applySettings(
        const ReaderSettings(theme: ReaderTheme.dark, fontSize: 24),
      );
      await tester.pumpAndSettle();

      final updated = tester.widget<Container>(
        find.byKey(renderer.viewportKey),
      );
      expect(updated.color, mdPaletteFor(ReaderTheme.dark).background);
      expect(renderer.settings.fontSize, 24);
    });
  });
}
