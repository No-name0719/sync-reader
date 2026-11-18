/// epub page 模式「行边界页停」测试（页界不切字）。
///
/// 缺陷背景：page 模式原为「连续排版 + 视口高整数倍吸附」，页界落在行的
/// 中间 → 章题只显示上半截、页尾只显示半行。本测试把契约钉死在「页界落
/// 在行与行之间」：
///
/// 1. 连续翻页，落点必须**正落在行盒顶**（已知行边界），不是视口高整数倍；
/// 2. 落点处**没有行盒横跨**（没有任何字形被裁切）；
/// 3. 每页内容高度 ≤ 一屏、且接近一屏（页尾最多留一行空白）；
/// 4. 章题（标题块）整行可见：标题所在行盒不横跨落点；
/// 5. 往返一致性：next → prev 回到原落点；
/// 6. scroll 模式不受影响：仍是「滚一屏」。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/epub_page_probe.dart';
import '../../library/support/rich_minimal_epub.dart';

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_break');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}页界书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

/// 经 handler.createRenderer 打开渲染会话（真实解析链路）。
Future<EpubRenderer> openRenderer(
  BookFile bf, {
  ReaderSettings settings = ReaderSettings.defaults,
}) async => (await EpubFormatHandler().createRenderer(
  bf,
  settings,
  ProgressAnchor.empty,
)) as EpubRenderer;

Future<void> pumpReader(WidgetTester tester, EpubRenderer renderer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => renderer.buildView(context)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推进时钟越过 3s 节流窗口（保证测试结束时不留悬挂 Timer）。
Future<void> drainProgressThrottle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  testWidgets('page 模式：连续翻页落点均为行边界，页首页尾无半行', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(
        bf,
        settings: ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.page,
        ),
      ),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    final viewport = renderer.scrollController.position.viewportDimension;
    final landings = <double>[];

    for (var page = 0; page < 10; page++) {
      final moved = await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      if (!moved) break; // 文档末尾
      final offset = renderer.scrollController.offset;
      landings.add(offset);
      final atDocumentEnd =
          (offset - renderer.scrollController.position.maxScrollExtent).abs() <=
          1.0;

      // ① 落点是已知行边界（行盒顶 / 图片块块顶）**或章边界**（章起点：新
      //    章节另起一页，章起点即页起点）；末页例外——落在文档末尾
      //    （下方无内容，不存在切字）。
      final stops = epubDocumentStops(renderer);
      final chapterStarts = renderer.chapterStarts;
      expect(
        atDocumentEnd ||
            stops.any((s) => (s - offset).abs() <= 1.0) ||
            chapterStarts.any((c) => (c - offset).abs() <= 1.0),
        isTrue,
        reason:
            '第 $page 页落点 $offset 必须落在行边界或章边界上'
            '（候选：$stops；章边界：$chapterStarts）',
      );

      // ② 落点处没有行盒横跨 → 没有任何字形被裁切。
      expect(
        epubCutLines(renderer, offset),
        isEmpty,
        reason: '第 $page 页落点 $offset 处不得横跨行盒（行被页界切断）',
      );

      // ③ 本页内容高度：≤ 一屏（不溢出、不切字），且接近一屏（页尾最多
      //    留一行空白）。
      //    **例外**：本页止于**章边界**（新章节另起一页 → 上一章末页到章首
      //    为止，页尾留白到章首）或文档末尾。
      final contentHeight = renderer.pageContentHeight(viewport);
      expect(
        contentHeight,
        lessThanOrEqualTo(viewport + 0.5),
        reason: '本页内容高度不得超过一屏',
      );
      final pageEnd = offset + contentHeight;
      final endsAtChapter = renderer.chapterStarts.any(
        (c) => (c - pageEnd).abs() <= 1.0,
      );
      expect(
        contentHeight > viewport - 60 || endsAtChapter || atDocumentEnd,
        isTrue,
        reason:
            '本页内容高度应接近一屏（页尾最多留一行空白）；'
            '实际 $contentHeight（页尾 $pageEnd，章边界 ${renderer.chapterStarts}）',
      );
    }

    expect(landings.length, greaterThanOrEqualTo(6), reason: '至少翻过 6 页');
    expect(
      landings.toSet().length,
      landings.length,
      reason: '每次翻页的落点都应不同（页面确实前进了）',
    );

    await drainProgressThrottle(tester);
  });

  testWidgets('page 模式：翻页往返回到原落点（页结构稳定）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(
        bf,
        settings: ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.page,
        ),
      ),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 连翻 3 页，记录落点。
    final landings = <double>[];
    for (var i = 0; i < 3; i++) {
      await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      landings.add(renderer.scrollController.offset);
    }
    // 再翻 1 页，然后逐页退回，落点应逐一复原。
    await renderer.controller.nextPage();
    await tester.pumpAndSettle();
    for (var i = landings.length - 1; i >= 0; i--) {
      await renderer.controller.previousPage();
      await tester.pumpAndSettle();
      expect(
        renderer.scrollController.offset,
        closeTo(landings[i], 1.0),
        reason: '回退到第 ${i + 1} 页应复原落点',
      );
    }

    await drainProgressThrottle(tester);
  });

  testWidgets('page 模式：章题（标题块）整行可见，不被页界切半', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(
        bf,
        settings: ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.page,
        ),
      ),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 翻到章题所在的页：逐页检查「标题文本所在行盒」不被落点横跨。
    var checked = 0;
    for (var page = 0; page < 12; page++) {
      final moved = await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      if (!moved) break;
      final offset = renderer.scrollController.offset;
      for (final line in epubDocumentLineBoxes(renderer)) {
        final straddles = line.top < offset - 0.5 && line.bottom > offset + 0.5;
        expect(straddles, isFalse, reason: '第 $page 页落点切断了行盒');
      }
      checked++;
    }
    expect(checked, greaterThan(4));

    await drainProgressThrottle(tester);
  });

  testWidgets('page 模式：插图独占一页（不与上下文字挤在一起、不被切成两页）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(
        bf,
        settings: ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.page,
        ),
      ),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 插图块（原子区间）与页停候选——**翻页前**取（惰性窗口一旦滚过，块就
    // 不再构建，量不到了）。
    final images = epubImageBlocks(renderer);
    expect(images, isNotEmpty, reason: '夹具含一张插图');
    final stops = epubDocumentStops(renderer);

    // 逐页前进，记录落点（直到离开插图所在章）。
    final landings = <double>[];
    for (var page = 0; page < 12; page++) {
      final moved = await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      if (!moved) break;
      landings.add(renderer.scrollController.offset);
    }
    expect(landings.length, greaterThan(2), reason: '至少翻过 2 页');

    // 页起点只能落在块顶或块底，绝不能落在内部。
    for (final (top, bottom) in images) {
      for (final landing in landings) {
        final inside = landing > top + 0.5 && landing < bottom - 0.5;
        expect(
          inside,
          isFalse,
          reason: '落点 $landing 落在插图内部（$top..$bottom）→ 插图被切成两页',
        );
      }
    }

    // 插图块顶与块底都是页起点，且**相邻**（插图独占一页，页内无正文）。
    for (final (top, bottom) in images) {
      expect(
        stops.any((s) => (s - top).abs() <= 1.0),
        isTrue,
        reason: '插图块顶 $top 必须是页起点（插图另起一页）',
      );
      expect(
        stops.any((s) => (s - bottom).abs() <= 1.0),
        isTrue,
        reason: '插图块底 $bottom 必须是页起点（插图页到此结束）',
      );
      // 块顶与块底之间不得夹别的页起点（否则插图页里混进了正文）。
      final between = stops
          .where((s) => s > top + 1.0 && s < bottom - 1.0)
          .toList();
      expect(between, isEmpty, reason: '插图区间 $top..$bottom 内不得有页起点（插图须独占一页）');
      // 翻页过程中确实经过了插图页：块顶与块底都是落点。
      expect(
        landings.any((l) => (l - top).abs() <= 1.0),
        isTrue,
        reason: '插图块顶 $top 应是翻页落点（插图独占一页）',
      );
      expect(
        landings.any((l) => (l - bottom).abs() <= 1.0),
        isTrue,
        reason: '插图块底 $bottom 应是翻页落点（插图页到此结束）',
      );
    }

    await drainProgressThrottle(tester);
  });

  testWidgets('scroll 模式：nextPage 仍为「滚一屏」，不受页停影响', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(
        bf,
        settings: ReaderSettings.defaults.copyWith(
          pageMode: ReaderPageMode.scroll,
        ),
      ),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    final viewport = renderer.scrollController.position.viewportDimension;
    final before = renderer.scrollController.offset;
    expect(await renderer.controller.nextPage(), isTrue);
    await tester.pumpAndSettle();
    expect(
      renderer.scrollController.offset - before,
      closeTo(viewport, 1.0),
      reason: 'scroll 模式仍是滚一屏（连续滚动，不吸附行边界）',
    );

    await drainProgressThrottle(tester);
  });
}
