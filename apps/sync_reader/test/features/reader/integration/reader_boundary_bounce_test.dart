/// 阅读页的**统一边界回弹**（v1.4.4 / docs/10 §9.21）。
///
/// 目标（提示词 §3.1）：能翻就翻，**不能翻就原地轻微回弹**，而不是无声
/// 吞掉——四种格式同一套反馈，由宿主统一播放（渲染器只管自己的翻页）。
///
/// 本测试钉死：
/// 1. 翻页被首/末页挡住 → 正文向左（下一页）/向右（上一页）顶一下再回来；
/// 2. 回弹幅度 = 公共规格的 24px；
/// 3. 翻页成功 → 不回弹；
/// 4. 滚动模式 → 不回弹（连续滚动到文档末尾停住是正常行为）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/reader/contract/format_registry.dart';
import 'package:sync_reader/features/reader/contract/reader_settings.dart';
import 'package:sync_reader/features/reader/reader_page.dart';
import 'package:sync_reader/features/reader/reader_page_turn.dart';

import 'fakes.dart';

BooksCompanion _bookRow(String id) => BooksCompanion.insert(
  bookId: id,
  title: '假书名',
  format: 'txt',
  fileName: '$id.txt',
  contentHash: 'sha256:$id',
  sizeBytes: 128,
  tocFingerprint: 'tfp:0000000000000000',
  addedAt: 1000,
  localPath: Value('/books/x.txt'),
);

void main() {
  AppDatabase? db;
  ProviderContainer? container;

  tearDown(() async {
    container?.dispose();
    container = null;
    await db?.close();
    db = null;
  });

  /// 挂载阅读页（假渲染器），返回渲染器以便控制翻页返回值。
  Future<FakeRenderer> pumpReader(
    WidgetTester tester, {
    required ReaderSettings settings,
  }) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    await database.customSelect('SELECT 1').getSingle();
    db = database;
    final renderer = FakeRenderer();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(database),
        formatRegistryProvider.overrideWithValue(
          FormatRegistry()..register(FakeHandler(renderer: renderer)),
        ),
      ],
    );
    await db!.booksDao.upsertCompanion(_bookRow('b1'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container!,
        child: const MaterialApp(home: ReaderPage(bookId: 'b1')),
      ),
    );
    await tester.pump();
    await tester.pump();
    // 阅读设置（翻页方式）来自仓库；默认即分页，这里显式写一份。
    await tester.pump(const Duration(milliseconds: 2900));
    expect(settings.pageMode, ReaderPageMode.page);
    return renderer;
  }

  /// 正文视图的左边缘（回弹时它会横向偏移）。
  double bodyLeft(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(const ValueKey('fake-renderer-view'))).dx;

  testWidgets('翻页被末页挡住 → 正文向左顶一下再回来（统一回弹）', (tester) async {
    final renderer = await pumpReader(
      tester,
      settings: ReaderSettings.defaults,
    );
    renderer.controller.turnResult = false; // 已在末页

    final before = bodyLeft(tester);
    // 桌面热区右侧 → 翻下一页。
    await tester.tap(find.byKey(const ValueKey('reader-hot-next')));
    await tester.pump();
    // 回弹曲线为半正弦：峰值在动画中点（280ms 的一半）。
    await tester.pump(const Duration(milliseconds: 140));
    final during = bodyLeft(tester);
    expect(during, lessThan(before), reason: '翻下一页被挡 → 正文应向左顶一下');
    expect(
      before - during,
      closeTo(ReaderPageTurnSpec.overscroll, 1.0),
      reason: '回弹幅度 = 公共规格的 24px',
    );

    await tester.pumpAndSettle();
    expect(bodyLeft(tester), closeTo(before, 0.01), reason: '回弹结束后正文回到原位');
    expect(renderer.controller.turnCalls, [1], reason: '确实请求过翻页');
  });

  testWidgets('翻页被首页挡住 → 正文向右顶一下再回来', (tester) async {
    final renderer = await pumpReader(
      tester,
      settings: ReaderSettings.defaults,
    );
    renderer.controller.turnResult = false; // 已在首页

    final before = bodyLeft(tester);
    await tester.tap(find.byKey(const ValueKey('reader-hot-prev')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(bodyLeft(tester), greaterThan(before), reason: '翻上一页被挡 → 正文应向右顶一下');
    await tester.pumpAndSettle();
    expect(bodyLeft(tester), closeTo(before, 0.01));
    expect(renderer.controller.turnCalls, [-1]);
  });

  testWidgets('翻页成功 → 不回弹（正文不动）', (tester) async {
    final renderer = await pumpReader(
      tester,
      settings: ReaderSettings.defaults,
    );
    renderer.controller.turnResult = true;

    final before = bodyLeft(tester);
    await tester.tap(find.byKey(const ValueKey('reader-hot-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(bodyLeft(tester), closeTo(before, 0.01), reason: '翻页成功不应回弹');
    await tester.pumpAndSettle();
  });

  testWidgets('滚动模式 → 不回弹（连续滚动到末尾停住是正常行为）', (tester) async {
    final renderer = await pumpReader(
      tester,
      settings: ReaderSettings.defaults,
    );
    renderer.controller.turnResult = false;

    // 切到滚动模式（设置面板的「翻页方式」）。
    final repo = container!.read(readerSettingsRepositoryProvider);
    await repo.save(
      ReaderSettings.defaults.copyWith(pageMode: ReaderPageMode.scroll),
    );
    await tester.pumpAndSettle();

    final before = bodyLeft(tester);
    await tester.tap(find.byKey(const ValueKey('reader-hot-next')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(bodyLeft(tester), closeTo(before, 0.01), reason: '滚动模式不回弹');
    await tester.pumpAndSettle();
  });
}
