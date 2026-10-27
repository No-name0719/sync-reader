/// 阅读进度管线集成测试（FR-207 + FR-208 基础版）：
/// 假渲染器触发 onProgressChanged → 防抖 3s 落库（dirty=true + lastReadAt）；
/// 切后台立即落库（取消挂起防抖）；退出阅读页立即落库并结算阅读时长。
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
import 'package:sync_reader/features/reader/reader_page.dart';

import 'fakes.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final rendererHandle = FakeRenderer();

  /// 建内存库 + 写书行 + 挂载阅读页到就绪状态（假渲染器经 [rendererHandle]
  /// 注入，测试直接持有句柄触发进度上报）。
  Future<void> pumpReady(WidgetTester tester) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(FakeHandler(renderer: rendererHandle)),
        ),
      ],
    );
    await db.booksDao.upsertCompanion(
      BooksCompanion.insert(
        bookId: 'b1',
        title: '管线书',
        format: 'txt',
        fileName: 'b1.txt',
        contentHash: 'sha256:b1',
        sizeBytes: 128,
        tocFingerprint: 'tfp:0000000000000000',
        addedAt: 1000,
        localPath: const Value('/books/b1.txt'),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReaderPage(bookId: 'b1')),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  /// 各用例公共前置：绑定生命周期为前台（保持状态跨用例稳定）。
  void assumeResumed(WidgetTester tester) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  }

  testWidgets('防抖落库：进度上报后 3s 内不写，3s 后写入 dirty=true + lastReadAt', (
    tester,
  ) async {
    assumeResumed(tester);
    await pumpReady(tester);

    rendererHandle.emitProgress(
      const ProgressAnchor(
        locatorJson: '{"type":"fake","pos":9}',
        percent: 0.42,
      ),
      0.42,
    );

    // 防抖窗口内：未落库。
    await tester.pump(const Duration(seconds: 1));
    expect(await db.progressDao.getByBookId('b1'), isNull);

    // 3s 防抖到期：落库。
    await tester.pump(const Duration(seconds: 3));
    final row = await db.progressDao.getByBookId('b1');
    expect(row, isNotNull);
    expect(row!.locatorJson, '{"type":"fake","pos":9}');
    expect(row.percent, 0.42);
    expect(row.dirty, isTrue);

    final book = await db.booksDao.getById('b1');
    expect(book!.lastReadAt, isNotNull);
  });

  testWidgets('切后台立即落库：paused 事件冲掉挂起的防抖并结算时长', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);

    // 前台阅读 2 秒（时长累计）。
    await tester.pump(const Duration(seconds: 2));

    rendererHandle.emitProgress(
      const ProgressAnchor(
        locatorJson: '{"type":"fake","pos":7}',
        percent: 0.3,
      ),
      0.3,
    );
    // 未等防抖到期即切后台。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 100));

    final row = await db.progressDao.getByBookId('b1');
    expect(row, isNotNull, reason: '切后台必须立即落库（FR-207）');
    expect(row!.percent, 0.3);
    expect(row.dirty, isTrue);

    // 阅读时长同步结算（FR-208）。
    final book = await db.booksDao.getById('b1');
    expect(book!.totalSeconds, 2);

    // 回到前台后再等 4s：挂起的防抖已被取消，不产生新写入。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 4));
    final row2 = await db.progressDao.getByBookId('b1');
    expect(row2!.percent, 0.3);
  });

  testWidgets('退出阅读页立即落库：取消挂起防抖并结算阅读时长', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);

    rendererHandle.emitProgress(
      const ProgressAnchor(
        locatorJson: '{"type":"fake","pos":11}',
        percent: 0.66,
      ),
      0.66,
    );
    // 前台 5 秒后直接卸载页面（模拟退出）。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));

    final row = await db.progressDao.getByBookId('b1');
    expect(row, isNotNull, reason: '退出必须立即落库，不等 3s 防抖');
    expect(row!.locatorJson, '{"type":"fake","pos":11}');
    expect(row.percent, 0.66);

    final book = await db.booksDao.getById('b1');
    expect(book!.totalSeconds, 5, reason: 'FR-208：阅读时长随退出结算');
    expect(book.lastReadAt, isNotNull);
    expect(rendererHandle.disposed, isTrue);
  });
}
