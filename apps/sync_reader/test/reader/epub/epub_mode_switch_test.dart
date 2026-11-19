/// 翻页方式切换（scroll ⇄ page）回归测试。
///
/// 缺陷（用户实测）：从滚动方式切到分页方式时，**画面先闪回第一页/封面**，
/// 正文加载不全，翻一次页才恢复。
///
/// 根因：切换翻页方式会重建正文滚动视图（分页视图的包装结构与滚动视图
/// 不同），而滚动偏移**没有随视图一起保留**（滚动视图未挂 [PageStorageKey]，
/// 框架不保存/恢复偏移）→ 新视图从 0 起（= 文档开头/封面），画面先闪一下
/// 封面，之后渲染器再按「当前块 + 块内字符偏移」把位置找回来（要好几帧，
/// 中间那几帧正文还没建出来 = 加载不全）。
///
/// 契约：
/// 1. 切换后的**第一帧**就必须已经在阅读位置（不得闪回第一页/封面）；
/// 2. 切换后逻辑位置（spine / 块 / 块内字符偏移）不变；
/// 3. 切换后本页内容完整（页高接近一屏，不是半页/空白）。
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
import '../../library/support/rich_minimal_epub.dart';
import '../../library/support/text_only_epub.dart';

/// 纯文字夹具（无插图）：两种翻页方式的排版完全一致 → 切换不应引起任何位移。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_mode');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}模式切换书.epub');
  await file.writeAsBytes(buildTextOnlyEpub(paras: 60));
  return BookFile.fromPath(file.path);
}

/// 带封面/插图的夹具：page 模式下图片块改为**整页槽** → 排版整体位移，
/// 位置只能按逻辑位置（块 + 块内字符偏移）找回。
Future<BookFile> writeRichEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_mode2');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}模式切换插图书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng, paras: 40));
  return BookFile.fromPath(file.path);
}

Future<EpubRenderer> openRenderer(
  BookFile bf, {
  required ReaderPageMode mode,
}) async => (await EpubFormatHandler().createRenderer(
  bf,
  ReaderSettings.defaults.copyWith(pageMode: mode),
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

/// 切换翻页方式，返回**切换后第一帧**的观感。
///
/// 帧末回调的注册顺序 = 执行顺序：本回调先于「面板重建后重新定位」的回调
/// 执行 → 读到的就是**画面上那一帧**的状态（重建后重新定位是之后才做的事）。
Future<({double offset, bool blockBuilt})> switchModeAndReadFirstFrame(
  WidgetTester tester,
  EpubRenderer renderer,
  ReaderPageMode mode,
) async {
  double? firstFrameOffset;
  bool? firstFrameBlockBuilt;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    firstFrameOffset = renderer.scrollController.offset;
    // 当前块是否已经构建出来（未构建 = 那一帧正文是空的 = 加载不全）。
    firstFrameBlockBuilt =
        renderer.blockContextOf(renderer.positionBlockInSpine) != null;
  });
  renderer.applySettings(ReaderSettings.defaults.copyWith(pageMode: mode));
  await tester.pump();
  return (offset: firstFrameOffset!, blockBuilt: firstFrameBlockBuilt!);
}

void main() {
  testWidgets('scroll → page：第一帧即在阅读位置，不闪回第一页/封面', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 滚到文档中部（模拟已读一段）。
    renderer.scrollController.jumpTo(900);
    await tester.pumpAndSettle();
    final before = renderer.scrollController.offset;
    final spineBefore = renderer.positionSpine;
    final blockBefore = renderer.positionBlockInSpine;
    final charBefore = renderer.positionOffset;
    expect(before, greaterThan(100), reason: '前置条件：确实滚下去了');

    final firstFrame = await switchModeAndReadFirstFrame(
      tester,
      renderer,
      ReaderPageMode.page,
    );

    expect(
      firstFrame.offset,
      closeTo(before, 1),
      reason: '切换后的第一帧必须已在阅读位置（曾闪回第一页/封面）',
    );
    expect(firstFrame.blockBuilt, isTrue, reason: '切换后的第一帧正文必须已经构建出来（曾加载不全）');

    await tester.pumpAndSettle();
    expect(renderer.positionSpine, spineBefore);
    expect(renderer.positionBlockInSpine, blockBefore);
    expect(renderer.positionOffset, charBefore);
  });

  testWidgets('page → scroll：第一帧即在阅读位置', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    renderer.scrollController.jumpTo(900);
    await tester.pumpAndSettle();
    final before = renderer.scrollController.offset;

    final firstFrame = await switchModeAndReadFirstFrame(
      tester,
      renderer,
      ReaderPageMode.scroll,
    );

    expect(
      firstFrame.offset,
      closeTo(before, 1),
      reason: '切回滚动方式的第一帧也必须已在阅读位置',
    );
  });

  testWidgets('scroll → page：切换后本页内容完整（页高接近一屏）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    renderer.scrollController.jumpTo(900);
    await tester.pumpAndSettle();

    renderer.applySettings(
      ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
    );
    await tester.pumpAndSettle();

    final viewport = renderer.scrollController.position.viewportDimension;
    final pageHeight = renderer.pageContentHeight(viewport);
    expect(
      pageHeight,
      greaterThan(viewport - 80),
      reason: '本页内容应接近一屏（页尾最多留一行空白），实测 $pageHeight',
    );
  });

  testWidgets('带插图的书：切换后逻辑位置不变（排版位移后按逻辑位置找回）', (tester) async {
    final bf = (await tester.runAsync(writeRichEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    renderer.scrollController.jumpTo(1500);
    await tester.pumpAndSettle();
    final spineBefore = renderer.positionSpine;
    final blockBefore = renderer.positionBlockInSpine;
    final charBefore = renderer.positionOffset;

    renderer.applySettings(
      ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
    );
    await tester.pumpAndSettle();

    expect(renderer.positionSpine, spineBefore);
    expect(renderer.positionBlockInSpine, blockBefore);
    expect(renderer.positionOffset, charBefore);
  });
}
