/// MdRenderer 音量键翻页（FR-209）widget 测试：nextPage/previousPage 滚动
/// 一屏（视口高度），文档端头返回 false（md 暂无分页模式，两模式同语义）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/md/md_block_parser.dart';
import 'package:sync_reader/features/reader/formats/md/md_renderer.dart';

/// 多章长文：保证文档高度远超一屏（构造方式与 md_renderer_test 一致）。
String longDoc({int chapters = 6, int parasPerChapter = 30}) {
  final b = StringBuffer();
  for (var c = 0; c < chapters; c++) {
    b
      ..writeln('# 第$c章 标题行')
      ..writeln();
    for (var i = 0; i < parasPerChapter; i++) {
      b
        ..writeln('第$c章的第$i段内容，用于撑起足够的滚动高度，使滚动与定位可测。')
        ..writeln();
    }
  }
  return b.toString();
}

Future<void> pumpReader(WidgetTester tester, MdRenderer renderer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => renderer.buildView(context)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 推进时钟越过 3s 节流窗口（翻页触发节流上报，不留悬挂 Timer）。
Future<void> drainProgressThrottle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  testWidgets('nextPage 滚一屏、previousPage 返回、顶端边界 false', (tester) async {
    final doc = longDoc();
    final blocks = const MdBlockParser().parse(doc);
    final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    expect(
      await renderer.controller.previousPage(),
      isFalse,
      reason: '已在文档顶端，无实际位移',
    );
    expect(renderer.scrollController.offset, 0);

    expect(await renderer.controller.nextPage(), isTrue);
    await tester.pumpAndSettle();
    final viewport = renderer.scrollController.position.viewportDimension;
    expect(renderer.scrollController.offset, closeTo(viewport, 0.5));

    expect(await renderer.controller.previousPage(), isTrue);
    await tester.pumpAndSettle();
    expect(renderer.scrollController.offset, closeTo(0, 0.5));

    await drainProgressThrottle(tester);
  });

  testWidgets('滚到文档末尾后 nextPage 为边界 false', (tester) async {
    final doc = longDoc();
    final blocks = const MdBlockParser().parse(doc);
    final renderer = MdRenderer(blocks: blocks, documentLength: doc.length);
    addTearDown(renderer.dispose);
    await pumpReader(tester, renderer);

    // 惰性构建下 maxScrollExtent 随构建增长，循环滚到真实末尾。
    var moves = 0;
    while (await renderer.controller.nextPage()) {
      moves++;
      expect(moves, lessThan(200), reason: '防御死循环');
      await tester.pumpAndSettle();
    }
    expect(moves, greaterThan(0));
    expect(
      await renderer.controller.nextPage(),
      isFalse,
      reason: '已在文档末尾，无实际位移',
    );
    expect(await renderer.controller.previousPage(), isTrue);

    // 先让帧末复测链收敛，再推进时钟清空节流窗口（不留悬挂 Timer）。
    await tester.pumpAndSettle();
    await drainProgressThrottle(tester);
  });
}
