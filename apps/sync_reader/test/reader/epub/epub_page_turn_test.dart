/// EpubRenderer 音量键翻页（FR-209）widget 测试：沿全书滚动位置按视口高度
/// 前进/后退一页（page 模式 PageScrollPhysics 的吸附单位即视口高度），
/// 文档端头返回 false。构造方式沿用 epub_renderer_test（真实解析链路 +
/// runAsync IO + 同步分帧）。
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
  testWidgets('page 模式：nextPage 前进一页、previousPage 返回、顶端边界 false', (
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
    expect(
      renderer.scrollController.offset,
      closeTo(viewport, 1.0),
      reason: 'page 模式吸附单位 = 视口高度，jumpTo 落点与 snap 页一致',
    );

    expect(await renderer.controller.previousPage(), isTrue);
    await tester.pump();
    expect(renderer.scrollController.offset, closeTo(0, 1.0));

    await drainProgressThrottle(tester);
  });

  testWidgets('scroll 模式：nextPage 滚一屏，滚到末尾后为边界 false', (tester) async {
    final bf = (await tester.runAsync(writeEpubBook))!;
    final renderer = (await tester.runAsync(() => openRenderer(bf)))!;
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
