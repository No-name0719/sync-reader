/// epub page 模式的**滑动翻页**契约（v1.3.7：移动端改为左右滑动；
/// v1.4.4：改为统一的左右推移动画）。
///
/// v1.3.7 用户决定：移动端分页模式由「上下滑动」改为「**左右滑动**」
/// （与 txt 的横轴 PageView 一致）——正文不再随手指上下滑动（滑动会把正文
/// 拖到页中间 → 页界与可见内容对不齐），翻页由**横向滑动**驱动。
///
/// v1.4.4（docs/10 §9.21）：滑动改为**跟手**——位移 1:1 映射到页面位移，
/// 过阈值补完到目标页、不过阈值弹回原页、首/末页越界有阻尼；动画时长与
/// 缓动取自公共规格 [ReaderPageTurnSpec]（与 txt 等格式一致）。
///
/// 本测试钉死七条契约：
/// 1. **左滑** → 前进一页；落点恒为**页起点**（页起点链上有它）；
/// 2. **右滑** → 后退一页（精确往返）；
/// 3. 一次滑动只翻**一页**（与滑动幅度无关）；
/// 4. **纵向滑动无效**（分页模式不接受用户滚动，正文不会被拖走）；
/// 5. **跟手**：拖拽中的翻页进度 = 位移 ÷ 视口宽（1:1，无缩放/视差）；
/// 6. **不过阈值 → 弹回原页**（不翻页，落点不变）；
/// 7. **末页越界 → 阻尼**（位移被压住，松手回到原页）。
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
import 'package:sync_reader/features/reader/reader_page_turn.dart';

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
    expect((back - first).abs(), lessThan(1.0), reason: '右滑应精确回到上一页（页起点链保证往返）');
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

  // —— v1.4.4：跟手 + 阈值 + 越界（docs/10 §9.21）——

  testWidgets('跟手：拖拽中的翻页进度 = 位移 ÷ 视口宽（1:1）', (tester) async {
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

    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final gesture = await tester.startGesture(
      const Offset(200, 400),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(
      renderer.turnProgress,
      closeTo(100 / viewportWidth, 0.02),
      reason: '位移 1:1 映射到翻页进度（无缩放/视差）',
    );
    // 再拖一段，进度继续线性增长。
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(
      renderer.turnProgress,
      closeTo(200 / viewportWidth, 0.02),
      reason: '继续跟手（线性）',
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('不过阈值 → 弹回原页（不翻页）', (tester) async {
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
    // 位移小于阈值（视口宽 800 → 阈值 120px）：松手应弹回原页。
    await swipe(tester, -60);
    expect(renderer.scrollController.offset, before, reason: '未过阈值不得翻页（应弹回原页）');
    expect(renderer.turnProgress, 0, reason: '动画收尾后进度归零');
  });

  testWidgets('末页继续左滑 → 越界有阻尼，松手回到原页', (tester) async {
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

    // 先翻到文档末尾。
    var guard = 0;
    while (guard++ < 40) {
      final moved = await renderer.controller.nextPage();
      await tester.pumpAndSettle();
      if (!moved) break;
    }
    final atEnd = renderer.scrollController.offset;

    // 末页继续左滑：越界位移被阻尼（不超过一屏 + 24px），松手回到原页。
    final viewportWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    final gesture = await tester.startGesture(
      const Offset(200, 400),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-600, 0));
    await tester.pump();
    expect(
      renderer.turnProgress,
      lessThanOrEqualTo(
        1 + ReaderPageTurnSpec.overscroll / viewportWidth + 0.02,
      ),
      reason: '越界位移必须被阻尼（拖过头也只多走一点点）',
    );
    expect(renderer.turnProgress, greaterThan(0), reason: '仍有可见位移');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(
      renderer.scrollController.offset,
      closeTo(atEnd, 1.0),
      reason: '末页不得翻页（原地回弹）',
    );
  });
}
