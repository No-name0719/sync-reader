/// TxtRenderer 音量键翻页（FR-209）widget 测试：nextPage/previousPage 经
/// 视图面板注册的委托执行——page 模式跳相邻页（含首末章边界 false），
/// scroll 模式滚动一屏（含文档端头 false）。构造方式沿用
/// txt_renderer_widget_test（debugSyncPagination 同步分页适配 FakeAsync）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/contract/book_file.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_format_handler.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_locator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';

/// 三章长内容：保证分页与滚动余量充足。
final String bookText =
    '第一章 开端\n${'甲' * 2000}\n'
    '第二章 发展\n${'乙' * 2000}\n'
    '第三章 结局\n${'丙' * 2000}\n';

Future<BookFile> _writeBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_turn');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}翻页书.txt');
  await file.writeAsBytes(Uint8List.fromList(utf8.encode(bookText)));
  return BookFile.fromPath(file.path);
}

/// 打开渲染器并泵出视图（翻页委托由 page/scroll 面板在 initState 注册）。
Future<TxtRenderer> _pumpReader(
  WidgetTester tester,
  ReaderSettings settings,
) async {
  final bf = (await tester.runAsync(_writeBook))!;
  final renderer =
      (await tester.runAsync(
            () => TxtFormatHandler().createRenderer(
              bf,
              settings,
              ProgressAnchor.empty,
            ),
          ))!
          as TxtRenderer;
  addTearDown(renderer.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => renderer.buildView(context)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return renderer;
}

void main() {
  setUpAll(() {
    // FakeAsync 环境（isolate 消息不可达）：分页同步化，保证面板可完成加载。
    TxtPaginator.debugSyncPagination = true;
  });

  tearDownAll(() {
    TxtPaginator.debugSyncPagination = false;
  });

  group('page 模式', () {
    testWidgets('nextPage 翻一页；首章首页向前翻为全书边界 false', (tester) async {
      final r = await _pumpReader(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );

      expect(await r.controller.previousPage(), isFalse, reason: '已是全书首页');
      expect(r.positionChapter, 0);
      expect(r.positionOffset, 0);

      expect(await r.controller.nextPage(), isTrue);
      await tester.pump();
      expect(r.positionChapter, 0, reason: '章内翻页不切章');
      expect(r.positionOffset, greaterThan(0), reason: '翻到本章第二页');
    });

    testWidgets('末章末页向后翻为全书边界 false；向前翻落倒数第二页', (tester) async {
      final r = await _pumpReader(
        tester,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
      );
      // 恢复到末章末尾（restore → revision 自增 → 面板重载末章落末页）。
      final result = await r.controller.restore(
        ProgressAnchor(
          locatorJson: TxtLocator.encode(2, r.chapterCharLength(2)),
          percent: 1,
          hasProgress: true,
        ),
      );
      expect(result.mode, ReaderRestoreMode.exact);
      await tester.pumpAndSettle();
      expect(r.positionChapter, 2);

      expect(await r.controller.nextPage(), isFalse, reason: '已是全书末页');
      expect(await r.controller.previousPage(), isTrue);
      await tester.pump();
      expect(
        r.positionOffset,
        lessThan(r.chapterCharLength(2)),
        reason: '翻到末章倒数第二页',
      );
    });
  });

  group('scroll 模式', () {
    testWidgets('nextPage 滚动一屏；文档顶端向前滚为边界 false', (tester) async {
      final r = await _pumpReader(tester, ReaderSettings.defaults);

      expect(await r.controller.previousPage(), isFalse, reason: '已在文档顶端');
      expect(r.positionOffset, 0);

      expect(await r.controller.nextPage(), isTrue);
      await tester.pump();
      expect(r.positionOffset, greaterThan(0), reason: '向下滚动一屏后位置推进');
    });

    testWidgets('连续 nextPage 到文档末尾后为边界 false', (tester) async {
      final r = await _pumpReader(tester, ReaderSettings.defaults);

      var moves = 0;
      while (await r.controller.nextPage()) {
        moves++;
        expect(moves, lessThan(200), reason: '防御死循环');
        await tester.pump(); // 惰性章构建需帧推进 maxScrollExtent
      }
      expect(moves, greaterThan(0));
      expect(await r.controller.nextPage(), isFalse, reason: '已在文档末尾');

      expect(await r.controller.previousPage(), isTrue);
      await tester.pump();
      expect(
        r.positionOffset,
        lessThan(r.chapterCharLength(2)),
        reason: '向上滚一屏离开文档末尾',
      );
    });
  });
}
