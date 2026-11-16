/// EpubRenderer 音量键翻页（FR-209）widget 测试：page 模式落到**行边界
/// 页停**（页界不切字），scroll 模式滚一屏，文档端头返回 false。构造方式
/// 沿用 epub_renderer_test（真实解析链路 + runAsync IO + 同步分帧）。
///
/// 契约（v1.4 收紧）：page 模式的翻页落点必须
/// 1. 是**已知行边界**（行盒顶 / 图片块块顶）——比旧的「视口高整数倍」更强
///    （视口高整数倍通常落在行的中间，正是本缺陷的成因）；
/// 2. 落点处**没有行盒横跨**（没有任何字形被裁切）；
/// 3. 本页内容高度 ≤ 视口高（页尾留白，不溢出）。
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
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_turn');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}翻页书.epub');
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
  testWidgets('page 模式：nextPage 落到行边界页停（不切字）、previousPage 返回', (
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

    // 面板首帧定位把首块顶对齐视口顶（滚过顶部 padding），先归零再测边界。
    if (renderer.scrollController.offset > 0) {
      expect(await renderer.controller.previousPage(), isTrue);
      await tester.pump();
    }

    expect(await renderer.controller.previousPage(), isFalse, reason: '已在文档顶端');
    expect(renderer.scrollController.offset, 0);

    expect(await renderer.controller.nextPage(), isTrue);
    await tester.pump();
    final viewport = renderer.scrollController.position.viewportDimension;
    final offset = renderer.scrollController.offset;

    // ① 落点必须是已知行边界（行盒顶 / 图片块块顶）——比旧的「视口高整数倍」
    //    更强：视口高整数倍一般落在行的中间（旧实现即如此，会切字）。
    final stops = epubDocumentStops(renderer);
    expect(
      stops.any((s) => (s - offset).abs() <= 1.0),
      isTrue,
      reason: '落点 $offset 必须是行边界页停之一（候选：$stops）',
    );

    // ② 落点处不得有被裁的字形：没有行盒横跨落点。
    expect(
      epubCutLines(renderer, offset),
      isEmpty,
      reason: '落点 $offset 处不得横跨任何行盒（否则行被页界切断）',
    );

    // ③ 本页内容高度 ≤ 视口高（页尾留白，不溢出、不切字）。
    expect(
      renderer.pageContentHeight(viewport),
      lessThanOrEqualTo(viewport + 0.5),
      reason: '本页内容高度不得超过一屏',
    );
    expect(
      renderer.pageContentHeight(viewport),
      greaterThan(viewport - 80),
      reason: '本页内容高度应接近一屏（页尾最多留一行空白）',
    );

    expect(await renderer.controller.previousPage(), isTrue);
    await tester.pump();
    expect(renderer.scrollController.offset, closeTo(0, 1.0));

    await drainProgressThrottle(tester);
  });

  testWidgets('scroll 模式：nextPage 滚一屏，滚到末尾后为边界 false', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    // Q9：出厂默认改「分页」，滚动模式用例显式指定。
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

    var moves = 0;
    while (await renderer.controller.nextPage()) {
      moves++;
      expect(moves, lessThan(200), reason: '防御死循环');
      await tester.pump(); // 惰性块构建需帧推进 maxScrollExtent
    }
    expect(moves, greaterThan(0));
    expect(await renderer.controller.nextPage(), isFalse, reason: '已在文档末尾');
    expect(await renderer.controller.previousPage(), isTrue);

    await drainProgressThrottle(tester);
  });
}
