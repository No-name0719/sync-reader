import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/app.dart';

void main() {
  testWidgets('应用根组件渲染书库首页', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SyncReaderApp()));
    await tester.pumpAndSettle();
    expect(find.text('SyncReader'), findsOneWidget);
    expect(find.text('书库为空'), findsOneWidget);
  });
}
