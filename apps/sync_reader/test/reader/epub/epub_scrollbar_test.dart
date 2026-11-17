/// epub 阅读视图的滚动条契约（v1.3.5：分页视图不再挂框架自动滚动条）。
///
/// 缺陷背景（用户实测：「往下翻页时右侧的滚动条会上下挑动，内容是往下翻的」）：
/// 框架的桌面滚动条（[MaterialScrollBehavior.buildScrollbar] 在
/// Windows/macOS/Linux 给纵向滚动视图自动挂 [Scrollbar]）的**滑块长度与
/// 位置**来自滚动指标里的 `maxScrollExtent`——而 epub 正文是一个
/// **惰性列表**（`ListView.builder` + 变量高的块）：
///
/// - 未构建的块按「原型估高」计入总高；
/// - 离开惰性窗口被回收的块**退回估高**；
/// - epub 块高差异极大（整页插图 ≈500px、普通段落 ≈50px）。
///
/// 于是每翻一页（构建/回收一批块）总高估计就跳变数百像素（实测
/// maxScrollExtent：3795 → 3612 → 3450 → 3464 → 3038），滑块随之
/// **一边变长一边跳位**——就是用户看到的「上下挑动」。
///
/// 修法：分页视图（page 模式）**不挂**框架自动滚动条——分页视图里像素级
/// 滚动条本就没有意义（翻页是离散的），阅读位置由阅读器底部进度轨承载；
/// 这与 txt 分页（PageView，本就无滚动条）、md 滚动（ListView，有滚动条）
/// 的既有分工一致。
///
/// 本测试钉死三条契约：
/// 1. page 模式（桌面平台）：正文视图里**没有** [Scrollbar]；
/// 2. scroll 模式（桌面平台）：**仍有** [Scrollbar]（滚动视图要能拖）；
/// 3. page 模式的拖拽设备集合 = **仅触摸**（v1.3.7 用户决定：分页模式不用
///    鼠标拖动翻页，见 [kReaderTouchOnlyDragDevices]）；而**滚动模式**仍由
///    应用自己的 [AppScrollBehavior] 提供（含鼠标，桌面可拖动滚动）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/app.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/rich_minimal_epub.dart';

Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_bar');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}滚动条书.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

Future<EpubRenderer> openRenderer(
  BookFile bf, {
  required ReaderPageMode mode,
}) async {
  final r = await EpubFormatHandler().createRenderer(
    bf,
    ReaderSettings.defaults.copyWith(pageMode: mode),
    ProgressAnchor.empty,
  );
  return r as EpubRenderer;
}

/// 阅读视图根标记（用于定位视图**内部**的 ScrollConfiguration）。
const Key readerRootKey = ValueKey('epub-reader-root');

/// 以桌面平台打开阅读视图（Windows 才自动挂框架滚动条）。
///
/// [debugDefaultTargetPlatformOverride] 必须在测试体**结束前**复位
/// （框架在测试体结束时校验"没有基础调试变量被改动"），故用 try/finally。
Future<void> pumpReader(WidgetTester tester, EpubRenderer renderer) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  try {
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: Scaffold(
          body: KeyedSubtree(
            key: readerRootKey,
            child: Builder(
              builder: (context) => renderer.buildView(context),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  testWidgets('page 模式（分页视图）：不挂框架自动滚动条', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);

    await pumpReader(tester, renderer);

    expect(
      find.byType(Scrollbar),
      findsNothing,
      reason:
          '分页视图不得挂框架自动滚动条：其滑块长度/位置来自惰性列表的估算'
          '总高，翻页时会跳变（用户实测「滚动条上下挑动」）',
    );
    // 正文视图本身仍在（没把内容误删）。
    expect(find.byType(Scrollable), findsWidgets);
  });

  testWidgets('scroll 模式（滚动视图）：保留框架自动滚动条', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);

    await pumpReader(tester, renderer);

    expect(
      find.byType(Scrollbar),
      findsOneWidget,
      reason: '滚动视图要保留滚动条（可拖拽跳转）',
    );
  });

  testWidgets('page 模式：拖拽设备仅触摸（分页模式禁用鼠标拖动翻页）', (
    tester,
  ) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.page),
    ))!;
    addTearDown(renderer.dispose);

    await pumpReader(tester, renderer);

    // v1.3.7 用户决定：分页模式**不用鼠标拖动翻页**（只用键盘 + 触摸滑动）。
    final behavior = ScrollConfiguration.of(
      tester.element(find.byType(ListView)),
    );
    expect(
      behavior.dragDevices,
      isNot(contains(PointerDeviceKind.mouse)),
      reason: '分页模式不得接受鼠标拖动',
    );
    expect(
      behavior.dragDevices,
      contains(PointerDeviceKind.touch),
      reason: '触摸滑动仍须可用（手机端主交互）',
    );
  });

  testWidgets('scroll 模式：拖拽设备仍含 mouse（桌面可拖动滚动正文）', (
    tester,
  ) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);

    await pumpReader(tester, renderer);

    // 滚动模式不受「仅触摸」限制——桌面仍可按住鼠标拖动滚动正文。
    final behavior = ScrollConfiguration.of(
      tester.element(find.byType(ListView)),
    );
    expect(
      behavior.dragDevices,
      contains(PointerDeviceKind.mouse),
      reason: '滚动模式仍应允许桌面鼠标拖动滚动正文',
    );
  });
}
