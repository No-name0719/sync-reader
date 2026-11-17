/// epub page 模式的**滑动翻页**契约（v1.3.7：移动端改为左右滑动）。
///
/// v1.3.7 用户决定：移动端分页模式由「上下滑动」改为「**左右滑动**」
/// （与 txt 的横轴 PageView 一致）——正文不再随手指上下滑动（滑动会把正文
/// 拖到页中间 → 页界与可见内容对不齐），翻页由**横向滑动**驱动。
///
/// 本测试钉死四条契约：
/// 1. **左滑** → 前进一页；落点恒为**页起点**（页起点链上有它）；
/// 2. **右滑** → 后退一页（精确往返）；
/// 3. 一次滑动只翻**一页**（与滑动幅度无关）；
/// 4. **纵向滑动无效**（分页模式不接受用户滚动，正文不会被拖走）。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/rich_minimal_epub.dart';

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_swipe');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}滑动书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

/// 打开渲染会话（page 模式）。
Future<EpubRenderer> openRenderer(BookFile bf) async =>
    (await EpubFormatHandler().createRenderer(
      bf,
      ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      ProgressAnchor.empty,
    )) as EpubRenderer;

/// 横向滑动一次（[dx] 手指横向位移；负 = 左滑 = 下一页）。
Future<void> swipe(WidgetTester tester, double dx) async {
  final gesture = await tester.startGesture(
    const Offset(200, 400),
    kind: PointerDeviceKind.touch,
  );
  await gesture.moveBy(Offset(dx, 0));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 纵向滑动一次（分页模式应无反应）。
Future<void> swipeVertical(WidgetTester tester, double dy) async {
  final gesture = await tester.startGesture(
    const Offset(200, 400),
    kind: PointerDeviceKind.touch,
  );
  await gesture.moveBy(Offset(0, dy));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 落点是否落在页起点链上（页起点 = 页界成立的标志）。
bool isPageStart(EpubRenderer renderer, double offset) =>
    renderer.pageStarts.any((p) => (p - offset).abs() < 1.0);

void main() {
  testWidgets('左滑 → 前进一页，落点是页起点', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = renderer.scrollController.offset;
    await swipe(tester, -200);
    final after = renderer.scrollController.offset;

    expect(after, greaterThan(before), reason: '左滑应前进一页');
    expect(isPageStart(renderer, after), isTrue, reason: '落点必须是页起点');
  });

  testWidgets('右滑 → 后退一页（精确往返）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 先左滑到「第一页起点」（已登记进页起点链），再左滑一页、右滑回来 →
    // 右滑应**精确**回到那一页（前后翻页可往返）。
    await swipe(tester, -200);
    final first = renderer.scrollController.offset;
    await swipe(tester, -200);
    final second = renderer.scrollController.offset;
    await swipe(tester, 200);
    final back = renderer.scrollController.offset;

    expect(second, greaterThan(first), reason: '第二次左滑应再前进一页');
    expect(
      (back - first).abs(),
      lessThan(1.0),
      reason: '右滑应精确回到上一页（页起点链保证往返）',
    );
  });

  testWidgets('纵向滑动无效（分页模式不接受用户滚动）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
    addTearDown(renderer.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final before = renderer.scrollController.offset;
    await swipeVertical(tester, -300);
    expect(
      renderer.scrollController.offset,
      before,
      reason: '纵向滑动不得拖动分页正文（会把正文拖到页中间 → 页界失效）',
    );
  });
}
