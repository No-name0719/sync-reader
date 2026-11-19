/// epub「推入页窗口」的页界回归测试（v1.4.6，用户实测：「现在左右翻页渲染
/// 时还是会有 1 瞬间被截断的行出现」）。
///
/// 缺陷背景：左右翻页是**双窗口交接**——槽 A = 当前页（连续列表 + 页尾裁剪），
/// 槽 B = 推入页（目标页的**复制渲染**）。旧实现的槽 B 是「固定高度的窗口 +
/// ClipRect」：
///
/// 1. 高度在**起翻瞬间**算一次就**冻住**（`_incomingHeight`）；
/// 2. 候选未知时直接给满**一屏**（旧 `pageHeightAt` 的兜底）——整屏的切线
///    落在任意 y 上，会把一行字拦腰切断；而主视口的同一场景是**保守收尾**
///    （安全边界 → 内容末尾 → 留白），两者口径不一致；
/// 3. 目标页的块**恰好卡在惰性窗口的边界**上（只预建一屏）→ 推入页的块
///    常常还没构建，页停候选也测不到。
///
/// 本测试钉死：
/// 1. **页界口径**：页结构的内容高度计算在候选未知时**绝不退化成整屏**
///    （纯 Dart，可单测）；
/// 2. **推入页与落点页同界**：翻页收尾时推入页的页界 == 落点页的页界
///    （否则收尾瞬间页面会跳一下）；
/// 3. **推入页有内容**：翻页途中推入页的复制块已构建（预建两屏的效果）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_page_structure.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/rich_minimal_epub.dart';

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp(
    'sync_reader_epub_incoming',
  );
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}推入页书.epub');
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

/// 推入页的复制块（key 形如 `epub-incoming-3`）。
final Finder incomingBlocks = find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('epub-incoming-'),
);

void main() {
  group('页结构：一页内容高度（保守口径，纯 Dart）', () {
    test('有下一个页起点时：页高 = 页终点 - 起点', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(
        [for (var i = 0; i < 10; i++) EpubStop.text(i * 30.0)],
        safeBounds: [for (var i = 0; i < 10; i++) i * 30.0],
      );

      // 页终点 = 一屏之内**最靠下**的行边界（页尾留白不足一行）：
      // 起点 0 → 终点 90（候选 30/60/90 都在一屏内）。
      expect(pages.contentHeightAt(0, 100), 90);
      expect(pages.contentHeightAt(30, 100), 90);
      // 起点不是候选时：向后找最近的下一个页起点（120）。
      expect(pages.contentHeightAt(35, 100), 85);
    });

    test('候选未知时：退到安全边界，绝不退化成整屏', () {
      final pages = EpubPageStructure(viewport: 100);
      // 没有页停候选，只有安全边界（行落点）。
      pages.setStops(const [], safeBounds: const [30, 70]);

      // 起点 0：区间 (0.5, 100] 内最后一条安全边界 = 70 → 页高 70。
      expect(pages.contentHeightAt(0, 100), 70);
      // 起点 80：区间内没有安全边界，且内容末尾未知 → **留白**（0）。
      expect(
        pages.contentHeightAt(80, 100),
        0,
        reason: '连安全边界都没有时宁可留白，也不露出被切断的半行',
      );
    });

    test('候选未知且已到文档末尾：整段露出，不切任何字', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(const [], safeBounds: const [], contentEnd: 60);

      expect(pages.contentHeightAt(0, 100), 60);
      expect(pages.contentHeightAt(80, 100), 0);
    });

    test('任何情况下都不返回整屏（整屏的切线会拦腰切断一行）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(const [], safeBounds: const []);

      for (final start in [0.0, 40.0, 80.0, 200.0, 1e9]) {
        expect(
          pages.contentHeightAt(start, 100),
          lessThan(100),
          reason: '起点 $start 的页高不得等于整屏',
        );
      }
    });
  });

  testWidgets('推入页的页界 == 落点页的页界（收尾不跳页）', (tester) async {
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

    final viewport = renderer.scrollController.position.viewportDimension;

    // 目标页起点（只读探测）。
    final target = renderer.pageTurnTargetFor(1);
    expect(target, isNotNull, reason: '第一页应有下一页起点');
    final incomingHeight = renderer.pageContentHeightAt(target!, viewport);
    expect(
      incomingHeight,
      lessThan(viewport),
      reason: '推入页的页界不得等于整屏（会露出被截断的半行）',
    );

    // 真翻一页（走左右推移动画），落点后页界应与推入页一致。
    expect(await renderer.controller.nextPage(), isTrue);
    await tester.pumpAndSettle();

    final committedHeight = renderer.pageContentHeight(viewport);
    expect(
      (committedHeight - incomingHeight).abs(),
      lessThanOrEqualTo(2.0),
      reason:
          '推入页页界 $incomingHeight 与落点页页界 $committedHeight 不一致'
          ' → 收尾瞬间页面会跳一下',
    );

    await drainProgressThrottle(tester);
  });

  testWidgets('翻页途中：推入页的复制块已构建（预建两屏 → 目标页总是就绪）', (tester) async {
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

    // 起翻（键盘翻页走视图层的左右推移动画）。
    expect(await renderer.controller.nextPage(), isTrue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(
      incomingBlocks,
      findsWidgets,
      reason:
          '翻页途中推入页应有内容（目标页的块未预建 → 推入页空白，'
          '旧实现还会按满一屏裁 → 露出被截断的半行）',
    );

    await tester.pumpAndSettle();
    await drainProgressThrottle(tester);
  });
}
