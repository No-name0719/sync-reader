/// 批量导入确认页 widget 测试（FR-109）：清单渲染、勾选交互、合计、
/// 按钮态、进度与汇总对话框。控制器注入假实现，不触真实 IO / file_picker。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/features/library/import/batch_import_controller.dart';
import 'package:sync_reader/features/library/import/batch_import_page.dart';
import 'package:sync_reader/features/library/import/book_import_service.dart';
import 'package:sync_reader/features/library/import/book_scanner.dart';

/// 假控制器：固定初始状态，startScan 不做真实扫描；importSelected 可配置
/// 为"推进到 done + 汇总"以驱动对话框分支。
class _FakeController extends BatchImportController {
  _FakeController(this._initial, {this.nextSummary});

  final BatchImportState _initial;

  /// 非空时 importSelected 会异步推进到 done 并携带该汇总。
  final ImportSummary? nextSummary;

  int importCalls = 0;

  @override
  BatchImportState build() => _initial;

  @override
  Future<void> startScan(String directoryPath) async {}

  @override
  Future<ImportSummary?> importSelected() async {
    importCalls++;
    state = state.copyWith(
      phase: BatchImportPhase.importing,
      progress: const ImportProgress(
        completed: 0,
        total: 2,
        currentName: '甲.txt',
      ),
      clearError: true,
    );
    final summary = nextSummary;
    if (summary == null) return null;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state = state.copyWith(
      phase: BatchImportPhase.done,
      summary: summary,
      clearProgress: true,
    );
    return summary;
  }
}

ScannedFile _file(String relativePath, {String ext = 'txt', int size = 1024}) =>
    ScannedFile(
      path: 'X:/dir/$relativePath',
      relativePath: relativePath,
      ext: ext,
      sizeBytes: size,
    );

/// 标准三行清单：新书 ×2（默认勾选）+ 库内重复 ×1（默认不勾）。
BatchImportState get _readyState => BatchImportState(
  phase: BatchImportPhase.ready,
  directoryPath: 'X:/dir',
  analyzedCount: 3,
  candidates: [
    ImportCandidate(file: _file('三体.txt'), contentHash: 'sha256:a'),
    ImportCandidate(
      file: _file('旧书.epub', ext: 'epub'),
      contentHash: 'sha256:b',
      duplicateOf: '库内书名',
      selected: false,
    ),
    ImportCandidate(
      file: _file('散文.md', ext: 'md'),
      contentHash: 'sha256:c',
    ),
  ],
);

Book _book(String id) => Book(
  bookId: id,
  title: '书$id',
  author: '',
  format: 'txt',
  fileName: '$id.txt',
  contentHash: 'sha256:$id',
  sizeBytes: 1,
  tocFingerprint: 'tfp:0000000000000000',
  addedAt: 1,
  totalSeconds: 0,
);

/// 泵入确认页：默认按 [seed] 构造假控制器；[controller] 显式给定时以它为准
/// （供需要断言调用次数 / 配置汇总的用例复用）。
Future<void> _pumpPage(
  WidgetTester tester,
  BatchImportState seed, {
  _FakeController? controller,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        batchImportControllerProvider.overrideWith(
          () => controller ?? _FakeController(seed),
        ),
      ],
      child: const MaterialApp(
        home: BatchImportConfirmationPage(directoryPath: 'X:/dir'),
      ),
    ),
  );
  await tester.pump(); // 排空 initState 微任务（假 startScan 无 IO）。
}

Checkbox _checkboxAt(WidgetTester tester, int index) =>
    tester.widget<Checkbox>(find.byType(Checkbox).at(index));

void main() {
  testWidgets('渲染清单：相对路径 / 格式大小 / 已存在标记 / 默认勾选', (tester) async {
    await _pumpPage(tester, _readyState);

    expect(find.text('三体.txt'), findsOneWidget);
    expect(find.text('旧书.epub'), findsOneWidget);
    expect(find.text('散文.md'), findsOneWidget);
    // 去重标记与副标题。
    expect(find.text('已存在'), findsOneWidget);
    expect(find.textContaining('库内已有《库内书名》'), findsOneWidget);
    expect(find.textContaining('TXT · 1.00 KB'), findsOneWidget);
    // 勾选态：新书勾选、重复不勾。
    expect(_checkboxAt(tester, 0).value, isTrue);
    expect(_checkboxAt(tester, 1).value, isFalse);
    expect(_checkboxAt(tester, 2).value, isTrue);
    // 合计与按钮。
    expect(find.textContaining('已选 2 本'), findsOneWidget);
    expect(find.text('导入选中（2）'), findsOneWidget);
  });

  testWidgets('勾选交互：行勾选即时联动合计与按钮文案', (tester) async {
    await _pumpPage(tester, _readyState);

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(find.textContaining('已选 1 本'), findsOneWidget);
    expect(find.text('导入选中（1）'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    expect(find.textContaining('已选 2 本'), findsOneWidget);
  });

  testWidgets('全部取消：按钮禁用并显示未选择', (tester) async {
    await _pumpPage(tester, _readyState);

    await tester.tap(find.byType(Checkbox).at(0));
    await tester.pump();
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();

    expect(find.text('未选择任何文件'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.bySubtype<FilledButton>());
    expect(button.onPressed, isNull, reason: '0 勾选时导入按钮应禁用');
  });

  testWidgets('全选 / 反选', (tester) async {
    await _pumpPage(tester, _readyState);

    await tester.tap(find.text('反选'));
    await tester.pump();
    // 反选后：仅原本不勾的"已存在"行被勾上。
    expect(_checkboxAt(tester, 0).value, isFalse);
    expect(_checkboxAt(tester, 1).value, isTrue);
    expect(_checkboxAt(tester, 2).value, isFalse);
    expect(find.textContaining('已选 1 本'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(_checkboxAt(tester, 0).value, isTrue);
    expect(_checkboxAt(tester, 1).value, isTrue);
    expect(_checkboxAt(tester, 2).value, isTrue);
    expect(find.textContaining('已选 3 本'), findsOneWidget);
  });

  testWidgets('点击导入：调控制器一次，进度展示且交互冻结', (tester) async {
    final controller = _FakeController(_readyState);
    await _pumpPage(tester, _readyState, controller: controller);

    await tester.tap(find.bySubtype<FilledButton>());
    await tester.pump();

    expect(controller.importCalls, 1);
    expect(find.textContaining('正在导入（0/2）：甲.txt'), findsOneWidget);
    // 按钮转入禁用 + "导入中"。
    final button = tester.widget<FilledButton>(find.bySubtype<FilledButton>());
    expect(button.onPressed, isNull);
    expect(find.text('导入中…'), findsOneWidget);
    // 行勾选冻结。
    expect(_checkboxAt(tester, 0).onChanged, isNull);
    // 顶栏动作冻结。
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '全选'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('导入结束：弹出汇总对话框，关闭后返回', (tester) async {
    final summary = ImportSummary()
      ..imported.add(_book('01A'))
      ..failures['坏.txt'] = '读取失败';
    await _pumpPage(
      tester,
      _readyState,
      controller: _FakeController(_readyState, nextSummary: summary),
    );

    await tester.tap(find.bySubtype<FilledButton>());
    await tester.pump(); // importing 态
    await tester.pump(const Duration(milliseconds: 30)); // 假异步完成 → done
    await tester.pumpAndSettle();

    expect(find.text('批量导入完成'), findsOneWidget);
    expect(
      find.textContaining('成功 1 本'),
      findsOneWidget,
      reason: '汇总应含成功数（失败原因首条见控制器测试）',
    );

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    // 页面是根路由（无可再弹出）：对话框已关、页面保留。
    expect(find.text('批量导入完成'), findsNothing);
    expect(find.byType(BatchImportConfirmationPage), findsOneWidget);
  });

  testWidgets('扫描中：提示文案（不做 pumpAndSettle，避免不确定动画）', (tester) async {
    await _pumpPage(
      tester,
      const BatchImportState(phase: BatchImportPhase.scanning),
    );
    expect(find.text('正在扫描文件夹…'), findsOneWidget);
  });

  testWidgets('截断 / 跳过条目提示', (tester) async {
    await _pumpPage(
      tester,
      BatchImportState(
        phase: BatchImportPhase.ready,
        truncated: true,
        skippedCount: 2,
        candidates: _readyState.candidates,
        analyzedCount: 3,
      ),
    );
    expect(find.textContaining('扫描已截断'), findsOneWidget);
    expect(find.textContaining('2 个条目无法访问'), findsOneWidget);
  });
}
