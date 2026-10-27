/// pdf 视图纯 Flutter 组件 widget 测试：页码指示展示 + 页码跳转对话框
/// 校验。组件不依赖 pdfrx，全程不触发 PdfDocument 加载（测试环境无
/// pdfium.dll）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/formats/pdf/pdf_view_widgets.dart';

void main() {
  /// 挂载指示器并捕获宿主 context；[jumped] 收集跳转回调（0 起页码）。
  Future<void> pumpIndicator(
    WidgetTester tester, {
    required int pageCount,
    ValueNotifier<int>? pageIndex,
    List<int>? jumped,
  }) {
    BuildContext? hostContext;
    return tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            hostContext = context;
            return Scaffold(
              body: Center(
                child: PdfPageIndicator(
                  pageIndexListenable: pageIndex ?? ValueNotifier<int>(0),
                  pageCount: pageCount,
                  onTap: () => showPdfPageJumpDialog(
                    hostContext!,
                    pageCount: pageCount,
                    onJump: jumped == null ? (_) {} : jumped.add,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  group('PdfPageIndicator', () {
    testWidgets('展示 1 起页码（0 起 2 → "3 / 120"）', (tester) async {
      final pageIndex = ValueNotifier<int>(2);
      await pumpIndicator(tester, pageCount: 120, pageIndex: pageIndex);
      expect(find.text('3 / 120'), findsOneWidget);

      pageIndex.value = 119;
      await tester.pump();
      expect(find.text('120 / 120'), findsOneWidget);
    });

    testWidgets('退化文档（pageCount=0）显示占位', (tester) async {
      await pumpIndicator(tester, pageCount: 0);
      expect(find.text('–'), findsOneWidget);
    });
  });

  group('showPdfPageJumpDialog', () {
    testWidgets('输入合法页码 → 以 0 起页码回调并关闭', (tester) async {
      final jumped = <int>[];
      await pumpIndicator(tester, pageCount: 120, jumped: jumped);

      await tester.tap(find.byType(PdfPageIndicator));
      await tester.pumpAndSettle();
      expect(find.text('跳转到页'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '42');
      await tester.tap(find.text('跳转'));
      await tester.pumpAndSettle();

      expect(jumped, [41]);
      expect(find.text('跳转到页'), findsNothing); // 对话框已关闭
    });

    testWidgets('非法输入：显示校验错误且不回调', (tester) async {
      final jumped = <int>[];
      await pumpIndicator(tester, pageCount: 120, jumped: jumped);

      await tester.tap(find.byType(PdfPageIndicator));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '999');
      await tester.tap(find.text('跳转'));
      await tester.pump();

      expect(find.text('请输入 1–120 之间的整数页码'), findsOneWidget);
      expect(find.text('跳转到页'), findsOneWidget); // 对话框未关闭
      expect(jumped, isEmpty);

      await tester.enterText(find.byType(TextFormField), 'abc');
      await tester.tap(find.text('跳转'));
      await tester.pump();
      expect(jumped, isEmpty);
    });

    testWidgets('取消 → 不回调', (tester) async {
      final jumped = <int>[];
      await pumpIndicator(tester, pageCount: 120, jumped: jumped);

      await tester.tap(find.byType(PdfPageIndicator));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextFormField), '7');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(jumped, isEmpty);
      expect(find.text('跳转到页'), findsNothing);
    });
  });
}
