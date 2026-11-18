/// epub page 模式「目录跳转 + 新章节另起一页」回归测试（v1.3.3）。
///
/// 用户实测反馈：「偶尔通过章节选择跳转时会出现上一次提交修复的连续翻页
/// 问题，且通过翻页方式到新的章节时没有新起一页」。
///
/// 本测试钉死两条契约：
///
/// **① 目录跳转 = 位置语义断裂**
/// - 跳转是**位置语义断裂**：新位置与旧位置的页起点不再相邻 → 旧页起点链
///   必须作废（否则弹道吸附把页面吸回旧位置、翻页沿旧链跳回旧章）；
/// - **定位期间不得产生弹道仿真**：定位循环用 `jumpTo` 逐步逼近目标块，而
///   `jumpTo` 末尾必触发 `goBallistic(0)`；弹道会把刚跳到的位置又拉回去 →
///   定位永不收敛，页面在旧位置与目标之间来回翻（=「连续翻页」）；
/// - 跳转落点**登记为新页起点**（翻页往返以它为锚）。
///
/// **② 新章节另起一页**
/// - 章节边界（spine 边界）= 页起点：页终点不得越过它，章题不与上一章正文
///   同页；上一章的末页到此为止（页尾留白到章首）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/density_skew_epub.dart';
import '../../library/support/epub_page_probe.dart';
import '../../library/support/rich_minimal_epub.dart';

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_jump');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}跳转书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

/// 写入「字符密度与像素密度悬殊」的 epub 到临时目录（真实文件 IO）。
Future<BookFile> writeDensitySkewBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_skew');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}密度悬殊.epub');
  await file.writeAsBytes(buildDensitySkewEpub(picBytes: tinyPng));
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

/// 第二章的目录条目（锚点 = spine 锚点）。
const TocEntry chapter2Entry = TocEntry(
  title: '第二章 转折',
  level: 0,
  anchor: EpubSpineAnchor(spineIndex: 1, href: 'chapter2.xhtml'),
);

/// 逐帧推进（观察弹道/动画是否把位置拉走）。
Future<void> pumpFrames(WidgetTester tester, int frames) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('① 目录跳转：位置语义断裂', () {
    testWidgets('跳转落到目标章，且落点稳定不被弹道拉回（不连翻）', (tester) async {
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

      // 先翻几页：制造一条**旧页起点链**（跳转前的位置）。
      for (var i = 0; i < 3; i++) {
        await renderer.controller.nextPage();
        await tester.pumpAndSettle();
      }
      final oldChain = renderer.pageStarts;
      expect(oldChain.length, greaterThan(1), reason: '应有旧页起点链');

      // 目录跳转到第二章。
      final jump = renderer.controller.jumpTo(chapter2Entry);
      await pumpFrames(tester, 40);
      await jump;

      // ① 跳转必须真的落到第二章（旧实现被弹道拉回，落点停在上一章）。
      expect(
        renderer.positionSpine,
        1,
        reason: '跳转后应位于第二章（spine 1），实际 ${renderer.positionSpine}',
      );

      // ② 落点稳定：推进多帧后位置不得漂移（弹道不得把页面吸回旧位置）。
      final landing = renderer.scrollController.offset;
      await pumpFrames(tester, 40);
      expect(
        renderer.scrollController.offset,
        closeTo(landing, 1.0),
        reason: '跳转落点 $landing 不得被弹道吸附拉走（连续翻页）',
      );

      // ③ 旧页起点链作废：链里只剩跳转落点，不得再有跳转前的页起点。
      final stale = renderer.pageStarts.where((p) => (p - landing).abs() > 1.0);
      expect(stale, isEmpty, reason: '跳转后旧页起点链必须作废，仍残留：$stale（旧链 $oldChain）');

      await drainProgressThrottle(tester);
    });

    testWidgets('跳转后按一次 ↓ 只前进一页（不连翻）', (tester) async {
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

      for (var i = 0; i < 3; i++) {
        await renderer.controller.nextPage();
        await tester.pumpAndSettle();
      }
      final jump = renderer.controller.jumpTo(chapter2Entry);
      await pumpFrames(tester, 40);
      await jump;
      final landing = renderer.scrollController.offset;

      // 按一次 ↓：落点必须是**紧邻的下一页起点**（一屏之内的最靠下候选）。
      expect(await renderer.controller.nextPage(), isTrue);
      await tester.pumpAndSettle();
      final after = renderer.scrollController.offset;
      final viewport = renderer.scrollController.position.viewportDimension;
      final stops = epubDocumentStops(renderer);
      final expected = stops
          .where((s) => s > landing + 1.0 && s <= landing + viewport + 1.0)
          .fold<double?>(
            null,
            (best, s) => best == null || s > best ? s : best,
          );
      expect(expected, isNotNull, reason: '落点之后一屏之内应有下一页起点（候选：$stops）');
      expect(
        after,
        closeTo(expected!, 1.0),
        reason:
            '按一次 ↓ 只应前进一页（落点 $landing → $after，'
            '期望 $expected）',
      );
      expect(
        after - landing,
        lessThanOrEqualTo(viewport + 1.0),
        reason: '一次按键最多前进一屏（不得连翻多页）',
      );

      // 再按一次 ↓：仍然只前进一页（不是每次都跳两页）。
      await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      expect(
        renderer.scrollController.offset - after,
        lessThanOrEqualTo(viewport + 1.0),
        reason: '第二次按键同样最多前进一屏',
      );

      await drainProgressThrottle(tester);
    });

    testWidgets('跳转后按 ↑ 回到落点的前一页，再按 ↓ 精确回到落点', (tester) async {
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

      final jump = renderer.controller.jumpTo(chapter2Entry);
      await pumpFrames(tester, 40);
      await jump;
      final landing = renderer.scrollController.offset;

      // ↑ 回到落点的**前一页**（上一章的末页）。
      expect(await renderer.controller.previousPage(), isTrue);
      await tester.pumpAndSettle();
      final prev = renderer.scrollController.offset;
      expect(prev, lessThan(landing), reason: '↑ 应回到落点之前的一页（$prev < $landing）');

      // ↓ 精确回到落点（页起点链往返一致）。
      expect(await renderer.controller.nextPage(), isTrue);
      await tester.pumpAndSettle();
      expect(
        renderer.scrollController.offset,
        closeTo(landing, 1.0),
        reason: '↓ 应精确回到跳转落点',
      );

      await drainProgressThrottle(tester);
    });

    testWidgets('章节字符密度与像素密度悬殊时，跳转仍落到目标章', (tester) async {
      // 夹具：第一章长段落（字符密度高）、第二章插图章（字符密度极低）、
      // 第三章大量短段落。粗跳估计若按全书字符比例换算，会落到目标之后
      // 一屏开外 → 目标块构建不出来 → 定位收敛不了 → 跳到别的章。
      final bf = (await tester.runAsync(writeDensitySkewBook))!;

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

      final jump = renderer.controller.jumpTo(
        const TocEntry(
          title: '第二章 插图',
          level: 0,
          anchor: EpubSpineAnchor(spineIndex: 1, href: 'chapter2.xhtml'),
        ),
      );
      await pumpFrames(tester, 60);
      await jump;

      expect(
        renderer.positionSpine,
        1,
        reason:
            '应跳到第二章（插图章），实际 spine=${renderer.positionSpine} '
            'block=${renderer.positionBlockInSpine} '
            'offset=${renderer.scrollController.offset}',
      );
      expect(renderer.positionBlockInSpine, 0, reason: '应落在第二章首块');

      await drainProgressThrottle(tester);
    });
  });

  group('② 新章节另起一页', () {
    testWidgets('上一章的末页止于章边界（章题不与上一章正文同页）', (tester) async {
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

      // 跳到第二章 → 落点即章起点。
      final jump = renderer.controller.jumpTo(chapter2Entry);
      await pumpFrames(tester, 40);
      await jump;
      final chapterStart = renderer.scrollController.offset;
      expect(
        renderer.chapterStarts.any((c) => (c - chapterStart).abs() <= 1.0),
        isTrue,
        reason: '章起点必须登记为页起点（章边界：${renderer.chapterStarts}）',
      );

      // ↑ 回到上一章的末页：该页的裁剪终点必须**正好**是章起点。
      expect(await renderer.controller.previousPage(), isTrue);
      await tester.pumpAndSettle();
      final viewport = renderer.scrollController.position.viewportDimension;
      final clipEnd =
          renderer.scrollController.offset +
          renderer.pageContentHeight(viewport);
      expect(
        clipEnd,
        closeTo(chapterStart, 1.0),
        reason:
            '上一章末页必须止于章边界（裁剪终点 $clipEnd，章起点 '
            '$chapterStart）——否则章题被挤在上一章正文同页',
      );

      // 章题的行盒不得落在上一页的可见区域内。
      final lines = epubDocumentLineBoxes(renderer);
      final headingLine = lines
          .where((l) => l.top >= chapterStart - 1.0)
          .fold<double?>(
            null,
            (best, l) => best == null || l.top < best ? l.top : best,
          );
      expect(headingLine, isNotNull, reason: '章题应有行盒');
      expect(
        headingLine!,
        greaterThanOrEqualTo(clipEnd),
        reason:
            '章题行盒（顶 ${headingLine.toStringAsFixed(1)}）不得落在上一页的'
            '可见区域内（裁剪终点 ${clipEnd.toStringAsFixed(1)}）',
      );

      await drainProgressThrottle(tester);
    });

    testWidgets('逐页翻到第二章时，落在章起点（新章另起一页）', (tester) async {
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

      final landings = <double>[];
      var guard = 0;
      while (guard++ < 30) {
        final moved = await renderer.controller.nextPage();
        await tester.pumpAndSettle();
        if (!moved) break;
        landings.add(renderer.scrollController.offset);
        if (renderer.positionSpine >= 1) break;
      }

      expect(renderer.positionSpine, 1, reason: '应翻到第二章');
      final chapterStart = renderer.scrollController.offset;
      expect(
        renderer.chapterStarts.any((c) => (c - chapterStart).abs() <= 1.0),
        isTrue,
        reason: '翻到第二章时应落在章起点（章边界：${renderer.chapterStarts}）',
      );

      // 上一页的裁剪终点 = 章起点（章题不在上一页）。
      final viewport = renderer.scrollController.position.viewportDimension;
      final prevClipEnd = chapterStart - renderer.pageContentHeight(viewport);
      expect(
        prevClipEnd,
        lessThanOrEqualTo(chapterStart + 1.0),
        reason: '上一页不得越过章边界',
      );

      await drainProgressThrottle(tester);
    });
  });
}
