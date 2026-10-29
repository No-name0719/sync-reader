/// MdRenderer widget 测试（少量冒烟）：分块渲染、滚动 → locator 上报、
/// restore 三分支、jumpTo 锚点映射、applySettings 生效、占位渲染。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
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
      // A10：段落显示文本带 2em 全角空格缩进前缀。
      expect(find.text('$mdParagraphIndent开头段落。'), findsOneWidget);
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
      expect(container.color, mdPaletteFor(ReaderTheme.paper).background);

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

  group('v1.1 A10 中文排版（缩进 + 两端对齐 + 列宽）', () {
    testWidgets('段落块前置 2em 全角空格缩进，标题块不缩进', (tester) async {
      const sample = '# 第一章\n\n开头段落。\n';
      final blocks = const MdBlockParser().parse(sample);
      final renderer = MdRenderer(
        blocks: blocks,
        documentLength: sample.length,
      );
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      // 段落 MarkdownBody 的 data 带缩进前缀（显示层，不改 sourceStart）。
      final paraBody = tester.widget<MarkdownBody>(
        find.byWidgetPredicate(
          (w) => w is MarkdownBody && w.data.contains('开头段落'),
        ),
      );
      expect(paraBody.data, '$mdParagraphIndent开头段落。');
      // 标题块不缩进（data 为原始 markdown 源）。
      final headBody = tester.widget<MarkdownBody>(
        find.byWidgetPredicate(
          (w) => w is MarkdownBody && w.data.contains('第一章'),
        ),
      );
      expect(headBody.data, '# 第一章');
    });

    testWidgets('正文列宽上限 720：宽屏水平留白居中', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final doc = longDoc(chapters: 2, parasPerChapter: 4);
      final blocks = const MdBlockParser().parse(doc);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final list = tester.widget<ListView>(find.byType(ListView));
      final padding = list.padding as EdgeInsets;
      expect(
        (1440 - padding.horizontal) / 2,
        closeTo(AppLayout.readerMaxWidth / 2, 0.5),
        reason: '内容列宽 = 720 居中（两侧留白对称）',
      );
      await drainProgressThrottle(tester);
    });
  });

  group('v1.1 能力扩展（A8 控制条）', () {
    testWidgets('jumpToPercent：滚到目标比例所在块，locator 同步', (tester) async {
      final doc = longDoc();
      final blocks = const MdBlockParser().parse(doc);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      // _scrollToBlock 内部 await endOfFrame：先 fire，再泵帧，后等待完成。
      final jump = renderer.jumpToPercent(0.5);
      await tester.pumpAndSettle();
      await jump;
      final locator = MdLocator.tryDecode(renderer.currentAnchor.locatorJson);
      expect(locator, isNotNull);
      expect(
        renderer.currentAnchor.percent,
        greaterThan(0.3),
        reason: '半程跳转落点在文档中部',
      );
      await drainProgressThrottle(tester);
    });

    testWidgets('isTocEntryCurrent：当前所在标题命中', (tester) async {
      final doc = longDoc(chapters: 3, parasPerChapter: 3);
      final blocks = const MdBlockParser().parse(doc);
      final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final jump = renderer.jumpToPercent(0.8);
      await tester.pumpAndSettle();
      await jump;
      final current = MdLocator.tryDecode(renderer.currentAnchor.locatorJson)!
          .headingIndex;
      TocEntry entryAt(int i) => TocEntry(
        title: '第$i章',
        level: 0,
        anchor: MdHeadingAnchor(headingIndex: i),
      );
      expect(renderer.isTocEntryCurrent(entryAt(current)), isTrue);
      expect(renderer.isTocEntryCurrent(entryAt(current + 1)), isFalse);
      await drainProgressThrottle(tester);
    });
  });
}
