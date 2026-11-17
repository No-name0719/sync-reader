/// epub 分页模式的**滚轮**契约（v1.3.7，用户实测反馈驱动）。
///
/// 用户实测：「分页模式下用滚轮会出现乱翻的情况」→ 决定**把滚轮从分页模式
/// 里彻底拿掉**：分页模式的翻页只由**键盘**（↑/↓/PageUp/PageDown/空格）与
/// **触摸滑动**控制；滚轮在分页模式下**既不翻页、也不滚动正文**（否则正文
/// 会在页中间自由滚动，页界随之失效）。
///
/// 本测试钉死：
/// 1. 分页模式：滚轮 → 位置**完全不动**（不翻页、不滚动）；
/// 2. 分页模式：键盘路径（[EpubRenderer.nextPage]，宿主按键即走它）→ 照常翻页；
/// 3. 滚动模式：滚轮 → 照常滚动（滚轮只在**分页**模式被拿掉）。
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
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_wheel');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}滚轮书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

/// 打开渲染会话（指定翻页模式）。
Future<EpubRenderer> openRenderer(BookFile bf, ReaderPageMode mode) async =>
    (await EpubFormatHandler().createRenderer(
      bf,
      ReaderSettings.defaults.copyWith(pageMode: mode),
      ProgressAnchor.empty,
    )) as EpubRenderer;

/// 挂载阅读视图。
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

/// 滚一格滚轮（纵向 100 逻辑像素 = Windows 一档）。
Future<void> wheelOnce(WidgetTester tester) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: const Offset(200, 300),
      scrollDelta: const Offset(0, 100),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('分页模式：滚轮不翻页、也不滚动正文', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    final before = renderer.scrollController.offset;
    for (var i = 0; i < 4; i++) {
      await wheelOnce(tester);
    }
    expect(
      renderer.scrollController.offset,
      before,
      reason: '分页模式下滚轮必须完全无效（既不翻页也不滚动）',
    );
    expect(
      renderer.pageStarts,
      isEmpty,
      reason: '滚轮不得产生任何页起点（没有翻页）',
    );
  });

  testWidgets('分页模式：键盘路径（nextPage）照常翻页', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 连翻 3 页：每次都要真的前进（页起点链有历史项时，弹道不得把页面拽回
    // 上一页 —— 那会让键盘翻页在两页间来回跳）。
    var previous = renderer.scrollController.offset;
    for (var i = 0; i < 3; i++) {
      final turned = await renderer.nextPage();
      await tester.pumpAndSettle();
      final now = renderer.scrollController.offset;
      expect(turned, isTrue, reason: '第 ${i + 1} 次键盘翻页应成功');
      expect(
        now,
        greaterThan(previous),
        reason: '第 ${i + 1} 次键盘翻页应前进（不得被弹道拽回上一页）',
      );
      previous = now;
    }
  });

  testWidgets('分页模式：鼠标拖动不翻页（触摸滑动仍可）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    final before = renderer.scrollController.offset;
    // 鼠标拖动（PointerDeviceKind.mouse）：分页模式不得被拖动翻页。
    final gesture = await tester.startGesture(
      const Offset(200, 400),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -260));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      renderer.scrollController.offset,
      before,
      reason: '分页模式不得用鼠标拖动翻页（只用键盘与触摸滑动）',
    );

    // **横向**触摸滑动仍然可以翻页（手机端的主交互不能被误伤；v1.3.7 起
    // 移动端分页由上下滑动改为左右滑动）。
    final touch = await tester.startGesture(
      const Offset(200, 400),
      kind: PointerDeviceKind.touch,
    );
    await touch.moveBy(const Offset(-200, 0));
    await touch.up();
    await tester.pumpAndSettle();

    expect(
      renderer.scrollController.offset,
      greaterThan(before),
      reason: '横向触摸滑动仍应能翻页（分页模式的主交互）',
    );
  });

  testWidgets('滚动模式：滚轮照常滚动（滚轮只在分页模式被拿掉）', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    final before = renderer.scrollController.offset;
    for (var i = 0; i < 3; i++) {
      await wheelOnce(tester);
    }
    expect(
      renderer.scrollController.offset,
      greaterThan(before),
      reason: '滚动模式下滚轮仍应滚动正文',
    );
  });
}
