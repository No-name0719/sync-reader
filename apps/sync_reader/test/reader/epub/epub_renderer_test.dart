/// EpubRenderer widget 测试：块化渲染（标题/粗斜体/图片）、双翻页模式、
/// 目录跳转、restore 三分支、进度往返（locator 落点一致性）、
/// locator 与 sync_core 互操作、设置热应用。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'package:sync_core/sync_core.dart' as core;
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_locator.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_theme.dart';

import '../../library/fake_handler.dart';
import '../../library/support/rich_minimal_epub.dart';

/// HtmlWidget 富文本内容断言（fwfh 经 RichText 渲染内联文本）。
Finder richTextContaining(String text) => find.byWidgetPredicate(
  (widget) => widget is RichText && widget.text.toPlainText().contains(text),
);

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_widget');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}富夹具.epub');
  await file.writeAsBytes(buildRichMinimalEpub(coverBytes: tinyPng));
  return BookFile.fromPath(file.path);
}

/// 经 handler.createRenderer 打开渲染会话（真实解析链路）。
///
/// 默认滚动模式（Q9 后出厂默认为分页）：restore/jumpTo 的落点语义按
/// 滚动坐标系断言；页模式的 PageScrollPhysics 吸附会在 jumpTo 后把位置
/// 吸附到最近视口页边界（jumpTo → goBallistic(0) 的物理行为），页模式
/// 本身由「页模式切换」用例单独覆盖。
Future<EpubRenderer> openRenderer(
  BookFile bf, {
  ReaderSettings? settings,
}) async => (await EpubFormatHandler().createRenderer(
  bf,
  settings ?? ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.scroll),
  ProgressAnchor.empty,
)) as EpubRenderer;

/// 解析目录（NCX 标题 + spine 序锚点）。
Future<List<TocEntry>> parseToc(BookFile bf) =>
    EpubFormatHandler().parseMetadata(bf).then((parsed) => parsed.toc);

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

/// 推进 FakeAsync 时钟越过 3s 节流窗口（含尾随补发），
/// 保证测试结束时不留悬挂 Timer（flutter_test invariant 检查）。
Future<void> drainProgressThrottle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
}

/// 与泵帧并发的 await：restore 定位循环内部 await endOfFrame，而测试环境
/// 只在 pump 时渲染帧——直接 await 会在"无新帧可等"时永久挂起。
Future<T> awaitWithPumping<T>(WidgetTester tester, Future<T> future) async {
  final done = Completer<void>();
  unawaited(future.whenComplete(done.complete));
  var rounds = 0;
  while (!done.isCompleted && rounds < 200) {
    await tester.pump(const Duration(milliseconds: 100));
    rounds++;
  }
  return future;
}

void main() {
  group('渲染（scroll 模式）', () {
    testWidgets('标题/粗斜体/列表可见，图片块与 hr 不抛异常', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      expect(find.byType(ListView), findsOneWidget);
      expect(richTextContaining('第一章 起点'), findsWidgets);
      expect(richTextContaining('加粗文本'), findsWidgets);
      expect(richTextContaining('斜体文本'), findsWidgets);
      expect(richTextContaining('引用名言一段'), findsWidgets);
      expect(richTextContaining('列表条目甲'), findsWidgets); // li 内容经 HtmlWidget
      expect(find.text('•'), findsWidgets); // 列表标记为独立 Text
      // 图片块：解析期已替换为 data URI（渲染走 Image.memory，解码失败有占位）。
      var hasDataUri = false;
      for (var i = 0; i < renderer.blockCount; i++) {
        if (renderer.blockHtml(i).contains('data:image/png;base64,')) {
          hasDataUri = true;
        }
      }
      expect(hasDataUri, isTrue, reason: 'img src 应在解析期归一化为 data URI');
      // 图片真实渲染（回归守护）：data URI 走 MemoryImage 渲染出 Image 组件，
      // 且无错误占位（此前仅断言 HTML 含 data URI，渲染层失败不会暴露）。
      expect(
        find.byWidgetPredicate((w) => w is Image && w.image is MemoryImage),
        findsWidgets,
      );
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
      expect(tester.takeException(), isNull);
      await drainProgressThrottle(tester);
    });

    testWidgets('极短书（第二章仅剩标题）渲染不崩', (tester) async {
      // 全部真实 IO 须经 runAsync（FakeAsync 环境下裸 IO future 永不完成）。
      Future<BookFile> writeShortBook() async {
        final dir = await Directory.systemTemp.createTemp(
          'sync_reader_epub_short',
        );
        addTearDown(() async {
          try {
            await dir.delete(recursive: true);
          } catch (_) {
            // 清理失败不阻塞测试
          }
        });
        final file = File('${dir.path}${Platform.pathSeparator}短书.epub');
        await file.writeAsBytes(
          buildRichMinimalEpub(coverBytes: tinyPng, paras: 0),
        );
        return BookFile.fromPath(file.path);
      }

      final bf = (await tester.runAsync(writeShortBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);
      expect(tester.takeException(), isNull);
      expect(renderer.blockCount, greaterThan(0)); // 标题块仍在
      expect(renderer.spineCount, 2);
      await drainProgressThrottle(tester);
    });
  });

  group('翻页模式', () {
    testWidgets('page 模式：连续内容 + 行边界页停物理，章首可见', (
      tester,
    ) async {
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

      final list = tester.widget<ListView>(find.byType(ListView));
      // page 模式用「行边界页停」物理（页界落在行与行之间，不切字），
      // 不是 Flutter 的视口高整数倍吸附。
      expect(list.physics, isA<EpubPageScrollPhysics>());
      expect(richTextContaining('第一章 起点'), findsWidgets);
      expect(tester.takeException(), isNull);
      await drainProgressThrottle(tester);
    });
  });

  group('目录跳转', () {
    testWidgets('jumpTo（EpubSpineAnchor 带 fragment）→ 滚到第二章首块', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      final toc = (await tester.runAsync(() => parseToc(bf)))!;
      await pumpReader(tester, renderer);

      // 锚点为 spine 锚点（带 fragment 亦然），toString 形态冻结。
      final entry = TocEntry(
        title: '第二章 转折',
        level: 0,
        anchor: const EpubSpineAnchor(
          spineIndex: 1,
          href: 'chapter2.xhtml#top',
        ),
      );
      expect(toc[1].anchor.toString(), 'epub:spine:1:chapter2.xhtml');

      final jumpFuture = renderer.controller.jumpTo(entry);
      await tester.pumpAndSettle();
      await jumpFuture;

      expect(richTextContaining('第二章 转折'), findsWidgets);
      expect(renderer.positionSpine, 1);
      expect(renderer.positionBlockInSpine, 0);
      expect(renderer.controller.percent, greaterThan(0));
      await drainProgressThrottle(tester);
    });
  });

  group('restore 三分支', () {
    testWidgets('noProgress：无历史进度 → 留在开头', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);

      final future = renderer.controller.restore(ProgressAnchor.empty);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.noProgress);
      expect(result.applied, ProgressAnchor.empty);
      expect(renderer.controller.percent, 0);
      expect(renderer.positionSpine, 0);
      expect(renderer.positionBlockInSpine, 0);
      await drainProgressThrottle(tester);
    });

    testWidgets('exact：locator 合法（含 URL 编码/fragment 容差）→ 滚到目标块', (
      tester,
    ) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      // href 归一化匹配：fragment 差异不影响 exact。
      final anchor = ProgressAnchor(
        locatorJson: EpubLocatorCodec.encode(
          spineIndex: 1,
          href: 'chapter2.xhtml#top',
          blockIndex: 2,
          charOffset: 8,
        ),
        percent: 0.3,
      );

      final future = renderer.controller.restore(anchor);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.exact);
      expect(result.applied, same(anchor)); // applied=原锚点
      expect(renderer.positionSpine, 1);
      expect(renderer.positionBlockInSpine, 2);
      expect(richTextContaining('第1段'), findsWidgets); // 第二章第 1 段（块 2）
      await drainProgressThrottle(tester);
    });

    testWidgets('degradedToPercent：损坏 locator → percent 定位最近章节开头', (
      tester,
    ) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      const anchor = ProgressAnchor(locatorJson: 'not-a-json{{', percent: 0.9);

      final future = renderer.controller.restore(anchor);
      await pumpReader(tester, renderer);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.degradedToPercent);
      expect(result.applied.locatorJson, '{}');
      expect(result.applied.percent, 0.9);
      // 0.9 × 总字符落在第二章 → 降级到第二章开头。
      expect(renderer.positionSpine, 1);
      expect(renderer.positionBlockInSpine, 0);
      await drainProgressThrottle(tester);
    });

    testWidgets('degradedToPercent：spineIndex 越界 / href 不匹配同样降级', (
      tester,
    ) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);

      final outOfRange = ProgressAnchor(
        locatorJson: EpubLocatorCodec.encode(
          spineIndex: 9,
          href: 'chapter2.xhtml',
          blockIndex: 0,
          charOffset: 0,
        ),
        percent: 0.8,
      );
      final mismatched = ProgressAnchor(
        locatorJson: EpubLocatorCodec.encode(
          spineIndex: 1,
          href: 'chapter9.xhtml',
          blockIndex: 0,
          charOffset: 0,
        ),
        percent: 0.8,
      );

      await pumpReader(tester, renderer);
      final r1 = await awaitWithPumping(
        tester,
        renderer.controller.restore(outOfRange),
      );
      expect(r1.mode, ReaderRestoreMode.degradedToPercent);
      final r2 = await awaitWithPumping(
        tester,
        renderer.controller.restore(mismatched),
      );
      expect(r2.mode, ReaderRestoreMode.degradedToPercent);
      expect(renderer.positionSpine, 1); // 0.8 落在第二章
      await drainProgressThrottle(tester);
    });
  });

  group('进度往返与 locator 互操作', () {
    testWidgets('跳转中途 → currentLocator → 新渲染器 restore 落在同一 spine+block', (
      tester,
    ) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final toc = (await tester.runAsync(() => parseToc(bf)))!;
      final first = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(first.dispose);
      await pumpReader(tester, first);

      // 跳到第二章后再下滚两屏（阅读中途）。
      final jumpFuture = first.controller.jumpTo(toc[1]);
      await tester.pumpAndSettle();
      await jumpFuture;
      final ctrl = first.scrollController;
      ctrl.jumpTo(ctrl.offset + 1200);
      await tester.pumpAndSettle();
      await drainProgressThrottle(tester);

      final locator = first.controller.currentLocator;
      final decoded = locator.decodeLocator()!;
      expect(decoded['type'], 'epub');
      expect(decoded['spineIndex'], 1);
      expect(first.controller.percent, greaterThan(0.3));

      // 用该锚点构造新渲染器 restore。
      final second = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(second.dispose);
      final future = second.controller.restore(locator);
      await pumpReader(tester, second);
      final result = await future;

      expect(result.mode, ReaderRestoreMode.exact);
      expect(second.positionSpine, decoded['spineIndex']);
      expect(second.positionBlockInSpine, decoded['blockIndex']);
      expect(
        second.controller.currentLocator.decodeLocator()!['blockIndex'],
        decoded['blockIndex'],
        reason: '同一字节解析结果确定，往返后块序号一致',
      );
      await drainProgressThrottle(tester);
    });

    testWidgets('渲染器产出的 locator 可被 sync_core 解码为 EpubLocator 且字段一致', (
      tester,
    ) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final toc = (await tester.runAsync(() => parseToc(bf)))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final jumpFuture = renderer.controller.jumpTo(toc[1]);
      await tester.pumpAndSettle();
      await jumpFuture;
      await drainProgressThrottle(tester);

      final locator = renderer.controller.currentLocator;
      final decoded = core.Locator.fromJsonString(locator.locatorJson);
      expect(decoded, isA<core.EpubLocator>());
      final epubLocator = decoded as core.EpubLocator;
      expect(epubLocator.spineIndex, renderer.positionSpine);
      expect(epubLocator.href, 'chapter2.xhtml');
      expect(epubLocator.blockIndex, renderer.positionBlockInSpine);
      expect(epubLocator.charOffset, renderer.positionOffset);
      expect(epubLocator.toJson()['type'], 'epub');
    });
  });

  group('设置热应用', () {
    testWidgets('字号/主题即时生效，位置近似保持', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final toc = (await tester.runAsync(() => parseToc(bf)))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final container = tester.widget<Container>(
        find.byKey(renderer.viewportKey),
      );
      expect(container.color, EpubThemeColors.of(ReaderTheme.paper).background);

      final jumpFuture = renderer.controller.jumpTo(toc[1]);
      await tester.pumpAndSettle();
      await jumpFuture;
      final spineBefore = renderer.positionSpine;

      renderer.applySettings(
        ReaderSettings.defaults.copyWith(fontSize: 24, theme: ReaderTheme.dark),
      );
      await tester.pumpAndSettle();

      final updated = tester.widget<Container>(
        find.byKey(renderer.viewportKey),
      );
      expect(updated.color, EpubThemeColors.of(ReaderTheme.dark).background);
      expect(renderer.settings.fontSize, 24);
      expect(renderer.positionSpine, spineBefore, reason: '重排后按当前块复位');
      await drainProgressThrottle(tester);
    });

    testWidgets('页模式切换：physics 变为行边界页停物理，无异常', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      renderer.applySettings(
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.physics, isA<EpubPageScrollPhysics>());
      expect(renderer.settings.pageMode, ReaderPageMode.page);
      expect(tester.takeException(), isNull);
      await drainProgressThrottle(tester);
    });
  });

  group('v1.1 A10 中文排版（缩进 + 两端对齐 + 列宽）', () {
    testWidgets('正文段落包装 justify 样式 + 2em 全角空格缩进', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      // 找一个段落块的 HtmlWidget：外层 div 注入 text-align: justify，
      // 段首插入两个全角空格（fwfh 无 text-indent 的等价实现）。
      final htmlWidgets = tester.widgetList<HtmlWidget>(
        find.byType(HtmlWidget),
      );
      final paragraphHtml = htmlWidgets
          .map((w) => w.html)
          .where((h) => h.contains('text-align: justify'))
          .toList();
      expect(paragraphHtml, isNotEmpty, reason: '正文段落应带 justify 包装');
      expect(
        paragraphHtml.first.startsWith(
          '<div style="text-align: justify">$epubParagraphIndent',
        ),
        isTrue,
      );
      // 标题块不带 justify 包装（只对正文段落缩进）。
      final headingHtml = htmlWidgets
          .map((w) => w.html)
          .where((h) => RegExp(r'^<h[1-6]').hasMatch(h))
          .toList();
      for (final h in headingHtml) {
        expect(
          h.contains('text-align: justify'),
          isFalse,
          reason: '标题/引用不缩进：$h',
        );
      }
      await drainProgressThrottle(tester);
    });

    testWidgets('正文列宽上限 720：宽屏水平留白居中', (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
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
    testWidgets('jumpToPercent：跳到目标比例所在 spine 并定位', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      // 定位循环内部 await endOfFrame：先 fire，再泵帧，后等待完成。
      final toEnd = renderer.jumpToPercent(1.0);
      await tester.pumpAndSettle();
      await toEnd;
      // 末尾定位按视口顶计量：落在最后一个有块的 spine，滚动已到文档底
      // （percent = 视口顶可见块比例，介于末页起点与 1 之间）。
      expect(renderer.positionSpine, renderer.spineCount - 1);
      expect(
        renderer.scrollController.offset,
        closeTo(renderer.scrollController.position.maxScrollExtent, 1.0),
      );
      expect(renderer.percent, greaterThan(0.5));

      final toStart = renderer.jumpToPercent(0);
      await tester.pumpAndSettle();
      await toStart;
      expect(renderer.positionSpine, 0, reason: '开头跳回首 spine');
      await drainProgressThrottle(tester);
    });

    testWidgets('isTocEntryCurrent：当前 spine 的目录条目命中', (tester) async {
      final bf = (await tester.runAsync(writeEpubBook))!;
      final toc = (await tester.runAsync(() => parseToc(bf)))!;
      final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
      addTearDown(renderer.dispose);
      await pumpReader(tester, renderer);

      final jump = renderer.controller.jumpTo(toc.last);
      await tester.pumpAndSettle();
      await jump;
      expect(renderer.isTocEntryCurrent(toc.last), isTrue);
      expect(renderer.isTocEntryCurrent(toc.first), isFalse);
      await drainProgressThrottle(tester);
    });
  });
}
