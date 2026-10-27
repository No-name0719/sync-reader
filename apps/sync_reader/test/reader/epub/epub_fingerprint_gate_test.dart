/// ReaderPage 指纹门集成测试（docs/05 §3.3 恢复规则 1，全格式生效）：
/// restore 之前比对 `book.tocFingerprint` 与 `parsed.tocFingerprint`，
/// 不一致且有历史进度 → 锚点降级为 raw（percent 保持）再交 restore；
/// 一致/目录为空（解析失败）/无进度 → 原锚点原样传入。
///
/// 做法：内存库 + 假 handler/渲染器（复用 reader_page 集成测试替身，
/// 见 test/features/reader/integration/fakes.dart）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/progress_anchor.dart';
import 'package:sync_reader/features/reader/contract/toc_entry.dart';
import 'package:sync_reader/features/reader/reader_page.dart';

import '../../features/reader/integration/fakes.dart';

/// 假 handler 解析指纹（fakes.dart 固定值）。
const _parsedFingerprint = 'tfp:0123456789abcdef';

void main() {
  AppDatabase? db;
  ProviderContainer? container;

  tearDown(() async {
    container?.dispose();
    container = null;
    await db?.close();
    db = null;
  });

  /// 建库 + 写书行（指纹可覆盖）+ 可选写进度 + 挂载阅读页。
  Future<FakeReaderController> pumpReady(
    WidgetTester tester, {
    String bookFingerprint = 'tfp:0000000000000000',
    ({String locatorJson, double percent})? progress,
    List<int> tocAnchors = const [],
  }) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    db = database;
    final renderer = FakeRenderer();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(
            FakeHandler(
              toc: [
                for (final i in tocAnchors)
                  TocEntry(title: '第一章$i', level: 0, anchor: i),
              ],
              renderer: renderer,
            ),
          ),
        ),
      ],
    );
    await db!.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: 'b1',
        title: '门测书',
        format: 'txt',
        fileName: 'b1.txt',
        contentHash: 'sha256:b1',
        sizeBytes: 128,
        tocFingerprint: bookFingerprint,
        addedAt: 1000,
        localPath: const Value('/books/b1.txt'),
      ),
    );
    if (progress != null) {
      await db!.progressDao.upsert(
        bookId: 'b1',
        locatorJson: progress.locatorJson,
        percent: progress.percent,
        dirty: true,
      );
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: MaterialApp(home: ReaderPage(bookId: 'b1')),
      ),
    );
    await tester.pump();
    await tester.pump();
    return renderer.controller;
  }

  testWidgets('指纹不一致且有进度 → restore 收到 raw 降级锚点（percent 保持）', (tester) async {
    final controller = await pumpReady(
      tester,
      bookFingerprint: 'tfp:0000000000000000', // ≠ 解析指纹
      progress: (
        locatorJson: '{"type":"txt","chapterIndex":3,"charOffset":9}',
        percent: 0.25,
      ),
      tocAnchors: const [0], // 解析目录非空（参与比对）
    );

    expect(controller.restoreCalls, hasLength(1));
    final received = controller.restoreCalls.single;
    expect(received.locatorJson, '{"type":"raw","ratio":0.25}');
    expect(received.percent, 0.25);
    expect(received.hasProgress, isTrue);
  });

  testWidgets('指纹一致 → restore 收到原锚点', (tester) async {
    final controller = await pumpReady(
      tester,
      bookFingerprint: _parsedFingerprint, // = 解析指纹
      progress: (
        locatorJson: '{"type":"txt","chapterIndex":3,"charOffset":9}',
        percent: 0.25,
      ),
      tocAnchors: const [0],
    );

    expect(
      controller.restoreCalls.single.locatorJson,
      '{"type":"txt","chapterIndex":3,"charOffset":9}',
    );
    expect(controller.restoreCalls.single.percent, 0.25);
  });

  testWidgets('目录为空（解析失败降级）→ 跳过比对，原锚点照传，不阻塞打开', (tester) async {
    final controller = await pumpReady(
      tester,
      bookFingerprint: 'tfp:0000000000000000', // ≠ 解析指纹，但目录为空
      progress: (
        locatorJson: '{"type":"txt","chapterIndex":1,"charOffset":0}',
        percent: 0.1,
      ),
      tocAnchors: const [],
    );

    expect(
      controller.restoreCalls.single.locatorJson,
      '{"type":"txt","chapterIndex":1,"charOffset":0}',
    );
    // 页面正常进入就绪态（渲染器视图可见）。
    expect(find.byKey(const ValueKey('fake-renderer-view')), findsOneWidget);
  });

  testWidgets('无历史进度 → 指纹门不介入，原样传空锚点', (tester) async {
    final controller = await pumpReady(
      tester,
      bookFingerprint: 'tfp:0000000000000000',
      tocAnchors: const [0],
    );

    expect(controller.restoreCalls.single, ProgressAnchor.empty);
  });
}
