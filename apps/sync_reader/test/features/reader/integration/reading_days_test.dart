/// 阅读时长按天归账集成测试（FR-208 C3）：阅读页 debugTick 注入时刻序列 →
/// debugFlushReadingDays 结算 → 断言 reading_days 按自然日拆分、
/// books.totalSeconds 累计不变；暂停不 tick 不归账；退出（dispose）路径
/// 同样逐日落库。内存库注入手法与 progress_pipeline_test 一致。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/reading_day.dart';
import 'package:sync_reader/features/reader/reader_page.dart';

import 'fakes.dart';

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  final rendererHandle = FakeRenderer();

  /// 建内存库 + 写书行 + 挂载阅读页到就绪状态（假渲染器，页面无进度管线干扰）。
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
        title: '按天归账书',
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

  /// 取阅读页状态：debugTick/debugFlushReadingDays 为 @visibleForTesting
  /// 钩子，经 dynamic 调用（状态类保持私有，生产 API 面不变）。
  dynamic pageState(WidgetTester tester) =>
      tester.state<State<ReaderPage>>(find.byType(ReaderPage));

  testWidgets('跨午夜归账：23:59:59 两侧的 tick 按自然日拆分，总时长不重复', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);
    final state = pageState(tester);

    // 3 秒：前一日 2 秒 + 次日 1 秒（跨午夜时刻序列注入）。
    state.debugTick(DateTime(2026, 10, 27, 23, 59, 58));
    state.debugTick(DateTime(2026, 10, 27, 23, 59, 59));
    state.debugTick(DateTime(2026, 10, 28, 0, 0, 0));
    await state.debugFlushReadingDays();

    final days = await db.readingDaysDao.daysByBook('b1');
    expect(days, hasLength(2), reason: '跨午夜会话拆成两行按天记录');
    // day DESC：次日行在前。
    expect(days[0].day, '2026-10-28');
    expect(days[0].seconds, 1);
    expect(days[1].day, '2026-10-27');
    expect(days[1].seconds, 2);

    // books.totalSeconds 累计正确（原路径行为不变）。
    final book = await db.booksDao.getById('b1');
    expect(book!.totalSeconds, 3);
    expect(book.lastReadAt, isNotNull);

    // 账本已清空：重复结算不再累计（防重入语义）。
    await state.debugFlushReadingDays();
    expect(await db.readingDaysDao.totalSeconds('b1'), 3);
    expect((await db.booksDao.getById('b1'))!.totalSeconds, 3);
  });

  testWidgets('同日多次结算：逐次累加同一日键（切后台反复发生不丢账）', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);
    final state = pageState(tester);

    // 第一段会话 2 秒后结算，第二段会话 1 秒后再结算（模拟两次切后台）。
    state.debugTick(DateTime(2026, 10, 27, 10, 0, 0));
    state.debugTick(DateTime(2026, 10, 27, 10, 0, 1));
    await state.debugFlushReadingDays();
    state.debugTick(DateTime(2026, 10, 27, 10, 5, 0));
    await state.debugFlushReadingDays();

    final days = await db.readingDaysDao.daysByBook('b1');
    expect(days, hasLength(1));
    expect(days.single.day, '2026-10-27');
    expect(days.single.seconds, 3);
    expect(await db.readingDaysDao.totalSeconds('b1'), 3);
    expect((await db.booksDao.getById('b1'))!.totalSeconds, 3);
  });

  testWidgets('暂停不归账：paused 后 tick 停摆，结算无按天记录', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);
    final state = pageState(tester);

    // 切后台：计时器停（didChangeAppLifecycleState 取消），推进 3 秒无 tick。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));
    await state.debugFlushReadingDays();

    expect(await db.readingDaysDao.daysByBook('b1'), isEmpty);
    expect(await db.readingDaysDao.totalSeconds('b1'), 0);
    expect((await db.booksDao.getById('b1'))!.totalSeconds, 0);
  });

  testWidgets('退出阅读页（dispose）路径：真实 tick 秒数逐日落库', (tester) async {
    assumeResumed(tester);
    await pumpReady(tester);

    // 前台 3 秒（真实 Timer.periodic，tick 时刻取 DateTime.now()，同日内）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));

    final today = readingDayKey(DateTime.now());
    final days = await db.readingDaysDao.daysByBook('b1');
    expect(days, hasLength(1));
    expect(days.single.day, today);
    expect(days.single.seconds, 3);
    expect((await db.booksDao.getById('b1'))!.totalSeconds, 3);
  });
}
