/// TxtRenderer 视图冒烟测试：page/scroll 双模式 buildView 可渲染出章首内容，
/// page 模式页脚可见（排版计算用 debugSyncPagination 同步化以适配 FakeAsync）。
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

/// 章内容足够长：确保末章远超 ListView cacheExtent，惰性断言稳定。
final String bookText =
    '第一章 开端\n${'甲' * 2000}\n'
    '第二章 发展\n${'乙' * 2000}\n'
    '第三章 结局\n${'丙' * 2000}\n';

Future<BookFile> _writeBook() async {
  final dir = await Directory.systemTemp.createTemp('sync_reader_txt_widget');
  addTearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {
      // 清理失败不阻塞测试
    }
  });
  final file = File('${dir.path}${Platform.pathSeparator}冒烟书.txt');
  await file.writeAsBytes(Uint8List.fromList(utf8.encode(bookText)));
  return BookFile.fromPath(file.path);
}

void main() {
  setUpAll(() {
    // FakeAsync 环境（isolate 消息不可达）：分页同步化，保证面板可完成加载。
    TxtPaginator.debugSyncPagination = true;
  });

  tearDownAll(() {
    TxtPaginator.debugSyncPagination = false;
  });

  testWidgets('page 模式：渲染章首页文本与页脚进度', (tester) async {
    final bf = (await tester.runAsync(_writeBook))!;
    final renderer = (await tester.runAsync(
      () => TxtFormatHandler().createRenderer(
        bf,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.page),
        ProgressAnchor.empty,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(PageView), findsOneWidget);
    expect(find.textContaining('第一章 开端'), findsWidgets, reason: '首屏页含章首内容');
    expect(find.textContaining('·'), findsWidgets, reason: '页脚含"章题 x/y · 进度"');

    renderer.dispose();
  });

  testWidgets('scroll 模式：按章分块渲染，视口外末章不构建（惰性）', (tester) async {
    final bf = (await tester.runAsync(_writeBook))!;
    final renderer = (await tester.runAsync(
      () => TxtFormatHandler().createRenderer(
        bf,
        ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.scroll),
        ProgressAnchor.empty,
      ),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => renderer.buildView(context)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.textContaining('第一章 开端'), findsWidgets, reason: '首章章题可见');
    expect(
      find.textContaining('第三章'),
      findsNothing,
      reason: '惰性构建：远超 cacheExtent 的末章不立即构建',
    );

    renderer.dispose();
  });
}
