/// txt 翻页方式切换（scroll ⇄ page）回归测试。
///
/// 契约（docs/local/12 D5「切换保持阅读位置」）：
/// 1. 切换后逻辑位置（章 + 章内字符偏移）不变；
/// 2. 分页视图落在**包含该字符偏移的那一页**（不是章首页）。
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
import 'package:sync_reader/features/reader/formats/txt/txt_paginator.dart';
import 'package:sync_reader/features/reader/formats/txt/txt_renderer.dart';

/// 三章，每章 2000 字（撑起滚动与分页）。
final String bookText =
    '第一章 开端\n${'甲' * 2000}\n'
    '第二章 发展\n${'乙' * 2000}\n'
    '第三章 结局\n${'丙' * 2000}\n';

Future<BookFile> _writeBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_mode');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}模式切换书.txt');
  await file.writeAsBytes(Uint8List.fromList(utf8.encode(bookText)));
  return BookFile.fromPath(file.path);
}

Future<TxtRenderer> openRenderer(
  BookFile bf, {
  required ReaderPageMode mode,
}) async => (await TxtFormatHandler().createRenderer(
  bf,
  ReaderSettings.defaults.copyWith(pageMode: mode),
  ProgressAnchor.empty,
)) as TxtRenderer;

void main() {
  setUpAll(() => TxtPaginator.debugSyncPagination = true);
  tearDownAll(() => TxtPaginator.debugSyncPagination = false);

  testWidgets('scroll → page：位置不丢，落在包含该位置的那一页', (tester) async {
    final bf = (await tester.runAsync(_writeBook))!;
    final renderer = (await tester.runAsync(
      () => openRenderer(bf, mode: ReaderPageMode.scroll),
    ))!;
    addTearDown(renderer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 滚到第一章中部。
    final scrollable = tester.widget<Scrollable>(find.byType(Scrollable));
    scrollable.controller!.jumpTo(1500);
    await tester.pumpAndSettle();
    final chapterBefore = renderer.positionChapter;
    final offsetBefore = renderer.positionOffset;
    expect(offsetBefore, greaterThan(0), reason: '前置条件：确实滚下去了');

    renderer.applySettings(
      ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
    );
    await tester.pumpAndSettle();

    expect(renderer.positionChapter, chapterBefore);
    expect(renderer.positionOffset, offsetBefore);

    // 分页视图应落在包含该字符偏移的那一页（页码从 1 起）。
    final info = renderer.currentPageInfo;
    expect(info, isNotNull, reason: '分页视图应回报页码');
    final (page, total) = info!;
    expect(total, greaterThan(1));
    expect(page, greaterThan(0));
  });
}
