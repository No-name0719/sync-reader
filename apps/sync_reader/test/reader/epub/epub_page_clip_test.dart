/// epub page 模式「页尾不切字 + 翻页不闪」回归测试（v1.3.2 性能优化）。
///
/// 缺陷背景（用户实测：「被截断的那一行/图片短暂出现 1–2s，然后移除或展示
/// 这一行」）。旧实现有两个坑叠在一起：
///
/// 1. **裁剪矩形根本没生效**：旧实现用 `ClipRect(clipper:)` 裁视口，但框架的
///    [RenderCustomClip] 会**缓存**裁剪矩形（`getClip` 只在缓存失效时重算），
///    而自定义 clipper 不会通知失效 → 裁剪矩形一直停在首帧算出的值（首帧
///    还没有行盒，多半是整屏）→ 页尾的半行/半图**始终露着**；
/// 2. **测量晚了一帧**：页终点测量放在帧末（post-frame），画这一帧时用的是
///    上一帧的旧落点 → 翻页/跳转瞬间先露出被切断的半行，收紧时又消失 →
///    「闪一下」。
///
/// 本测试钉死三条契约：
/// 1. **裁剪真的生效**：裁剪线以下的页尾像素全空白（没有半个字形）；
/// 2. **裁剪线落在行边界**上（不落在任何行盒中间 → 不切字）；
/// 3. **翻页中间态**（跳后尚未出帧）裁剪高度不是整屏（保守值，宁可留白）；
/// 4. 页结构的**保守裁剪**与**代次失效**（纯 Dart 单测）。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_format_handler.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_page_structure.dart';
import 'package:sync_reader/features/reader/formats/epub/epub_renderer.dart';

import '../../library/fake_handler.dart' show tinyPng;
import '../../library/support/epub_page_probe.dart';
import '../../library/support/rich_minimal_epub.dart';

/// 写入富夹具 epub 到临时目录（真实文件 IO，runAsync 包裹调用）。
Future<BookFile> writeEpubBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_epub_clip');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}页尾书.epub');
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

/// 视口截图的边界 Key（截图用于像素级断言「页尾无半个字形」）。
final Key viewportBoundaryKey = ValueKey('epub-clip-boundary');

/// 打开阅读视图（外层包 RepaintBoundary 便于取像素）。
Future<void> pumpReader(WidgetTester tester, EpubRenderer renderer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: viewportBoundaryKey,
          child: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 截取阅读视图的像素（RGBA）。
Future<Uint8List> captureViewport(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(viewportBoundaryKey),
  );
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 1.0));
  final data = await tester.runAsync(() async {
    final bytes = await image?.toByteData(format: ui.ImageByteFormat.rawRgba);
    return bytes;
  });
  image?.dispose();
  return data!.buffer.asUint8List();
}

/// 页尾区域（[fromLogical], 底部]）内的非背景像素数——裁剪失效时这里会有字。
int countInkBelow(
  Uint8List rgba,
  int width,
  int height,
  double fromLogical,
  Color background,
) {
  final start = fromLogical.ceil().clamp(0, height);
  final bgR = (background.r * 255).round();
  final bgG = (background.g * 255).round();
  final bgB = (background.b * 255).round();
  var ink = 0;
  for (var y = start; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      final a = rgba[i + 3];
      if (a == 0) continue;
      final diff = (r - bgR).abs() + (g - bgG).abs() + (b - bgB).abs();
      if (diff > 24) ink++;
    }
  }
  return ink;
}

/// 推进时钟越过 3s 节流窗口（保证测试结束时不留悬挂 Timer）。
Future<void> drainProgressThrottle(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
}

void main() {
  testWidgets('① 裁剪真的生效：页尾（裁剪线以下）无半个字形', (tester) async {
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
    final background = renderer.themeColors.background;

    for (var page = 0; page < 6; page++) {
      final moved = await renderer.controller.nextPage();
      await tester.pump();
      if (!moved) break;
      final clip = renderer.pageContentHeight(viewport);
      expect(
        clip,
        lessThan(viewport),
        reason:
            '第 $page 页裁剪高度应为「本页终点」，不得等于整屏'
            '（整屏 = 页尾会露出下一行的上半截）',
      );

      final rgba = await captureViewport(tester);
      final width = tester
          .renderObject<RenderBox>(find.byKey(viewportBoundaryKey))
          .size
          .width
          .round();
      final height = tester
          .renderObject<RenderBox>(find.byKey(viewportBoundaryKey))
          .size
          .height
          .round();
      final ink = countInkBelow(rgba, width, height, clip, background);
      expect(
        ink,
        0,
        reason:
            '第 $page 页裁剪线（$clip）以下仍有 $ink 个非背景像素 → '
            '页尾露出了被页界切断的半行/半图（裁剪未生效）',
      );
    }

    await drainProgressThrottle(tester);
  });

  testWidgets('② 裁剪线落在行边界上（页界不切字）', (tester) async {
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
    for (var page = 0; page < 6; page++) {
      final moved = await renderer.controller.nextPage();
      await tester.pump();
      if (!moved) break;
      final offset = renderer.scrollController.offset;
      final clip = renderer.pageContentHeight(viewport);
      final cut = offset + clip; // 裁剪线在文档坐标里的位置
      // 裁剪线必须落在已知行边界（行落点/插图块顶底）上，或落在文档末尾。
      final stops = epubDocumentStops(renderer);
      final onBoundary = stops.any((s) => (s - cut).abs() <= 1.0);
      final cutLines = epubCutLines(renderer, cut);
      expect(
        onBoundary || cutLines.isEmpty,
        isTrue,
        reason:
            '第 $page 页裁剪线 $cut 必须落在行边界上（候选：$stops）；'
            '被切断的行盒：$cutLines',
      );
    }

    await drainProgressThrottle(tester);
  });

  testWidgets('③ 翻页中间态：裁剪高度不是整屏（保守值，宁可留白）', (tester) async {
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
    for (var page = 0; page < 4; page++) {
      final moved = await renderer.controller.nextPage();
      // 跳后尚未出帧：此刻若「候选未知」就退化成整屏，用户会看到半行闪一下。
      final clip = renderer.pageContentHeight(viewport);
      expect(
        clip,
        lessThan(viewport),
        reason:
            '第 $page 页翻页中间态的裁剪高度不得等于整屏'
            '（会先露出被切断的半行/半图，下一帧又收紧 → 闪烁）',
      );
      await tester.pump();
      if (!moved) break;
    }

    await drainProgressThrottle(tester);
  });

  group('页结构：保守裁剪与代次失效（纯 Dart）', () {
    test('区间内最大的安全边界（保守裁剪用）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops(
        [for (var i = 0; i < 10; i++) EpubStop.text(i * 30.0)],
        safeBounds: [for (var i = 0; i < 10; i++) i * 30.0],
      );

      expect(pages.largestSafeWithin(0, 100), 90);
      expect(pages.largestSafeWithin(31, 100), 90);
      expect(pages.largestSafeWithin(31, 60), 60);
      expect(pages.largestSafeWithin(31, 45), isNull);
      expect(pages.largestSafeWithin(90, 60), isNull);
    });

    test('安全边界缺省时无保守落点（→ 留白而非切字）', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops([EpubStop.text(10)]);
      expect(pages.largestSafeWithin(0, 100), isNull);
      expect(pages.contentEnd, isNull);
    });

    test('代次变化：旧候选与旧页起点链一并作废', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops([
        for (var i = 0; i < 5; i++) EpubStop.text(i * 30.0),
      ], epoch: 1);
      pages.nextPageStart(0);
      expect(pages.chain, isNotEmpty);
      expect(pages.epoch, 1);

      // 代次变了（排版几何变化）→ 旧坐标对应旧排版，整体作废。
      pages.setStops([
        for (var i = 0; i < 5; i++) EpubStop.text(i * 30.0),
      ], epoch: 2);
      expect(pages.epoch, 2);
      expect(pages.chain, isEmpty);
      expect(pages.stopCount, 5);
    });

    test('同代次重复设置：候选整表替换，不累积', () {
      final pages = EpubPageStructure(viewport: 100);
      pages.setStops([
        for (var i = 0; i < 5; i++) EpubStop.text(i * 30.0),
      ], epoch: 1);
      pages.setStops([
        for (var i = 0; i < 5; i++) EpubStop.text(i * 30.0),
      ], epoch: 1);
      expect(pages.stopCount, 5);
    });
  });
}
