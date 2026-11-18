import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/onboarding.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/app/router.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/db/daos/app_settings_dao.dart';
import 'package:sync_reader/data/files/book_file_store.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  // 全局闸门在同一 isolate 内跨用例共享：每个用例前后复位。
  setUp(() => onboardingGate.reset(OnboardingStatus.unknown));
  tearDown(() => onboardingGate.reset(OnboardingStatus.unknown));

  test('闸门：标志不存在 → 需要首启；写入标志 → 已完成（不再打扰）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final gate = OnboardingGate();
    await gate.load(db.appSettingsDao);
    expect(gate.status, OnboardingStatus.pending);
    expect(gate.needsOnboarding, isTrue);

    await gate.markCompleted(db.appSettingsDao);
    expect(gate.status, OnboardingStatus.completed);
    expect(await db.appSettingsDao.getValue(OnboardingKeys.done), '1');

    // 重新读回：已完成。
    final reloaded = OnboardingGate();
    await reloaded.load(db.appSettingsDao);
    expect(reloaded.status, OnboardingStatus.completed);
    expect(reloaded.needsOnboarding, isFalse);
  });

  test('闸门：读表失败 → 按已完成处理，不阻断启动', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final broken = _BrokenAppSettingsDao(db);

    // 读失败 → 按「已完成」处理（首启页绝不阻断启动）。
    final gate = OnboardingGate();
    await gate.load(broken);
    expect(gate.status, OnboardingStatus.completed);

    // 落库失败 → 内存态照常切「已完成」（不把用户卡在首启页）。
    final gate2 = OnboardingGate();
    await gate2.markCompleted(broken);
    expect(gate2.status, OnboardingStatus.completed);
  });

  testWidgets('首启未完成：落点书库被改写到首启引导页（壳外全屏）', (tester) async {
    final env = await _setup(tester);

    onboardingGate.reset(OnboardingStatus.pending);
    await env.pump(tester);
    router.go('/');
    await _settle(tester);

    // 卡片与两个按钮都在。
    expect(find.text('坚果云同步'), findsOneWidget);
    expect(find.text('免费'), findsOneWidget);
    expect(find.text('多端续读'), findsOneWidget);
    expect(find.text('书库共享'), findsOneWidget);
    expect(find.text('不占本地'), findsOneWidget);
    expect(find.text('配置坚果云同步'), findsOneWidget);
    expect(find.text('暂不配置，先用本地'), findsOneWidget);
    // 首启页在 shell 外：没有导航栏，也没有书库内容。
    expect(find.text('书库'), findsNothing);
  });

  testWidgets('首启页「暂不配置，先用本地」：落标志后回落书库', (tester) async {
    final env = await _setup(tester);

    onboardingGate.reset(OnboardingStatus.pending);
    await env.pump(tester);
    router.go('/');
    await _settle(tester);

    await tester.tap(find.text('暂不配置，先用本地'));
    await _settle(tester);

    // 标志落库（下次启动不再弹首启页）。
    // 真 DB 查询必须在 runAsync 窗口内完成，否则 future 在 fakeAsync 区
    // 永不交付（同 settings_page_test 的教训）。
    final stored = await tester.runAsync(
      () => env.db.appSettingsDao.getValue(OnboardingKeys.done),
    );
    expect(stored, OnboardingKeys.doneValue);
    expect(onboardingGate.status, OnboardingStatus.completed);
    // 已进书库。
    expect(find.text('书库为空'), findsOneWidget);
    expect(find.text('暂不配置，先用本地'), findsNothing);
  });

  testWidgets('首启页「配置坚果云同步」：进入四步向导（壳外全屏）', (tester) async {
    final env = await _setup(tester);

    onboardingGate.reset(OnboardingStatus.pending);
    await env.pump(tester);
    router.go('/');
    await _settle(tester);

    await tester.tap(find.text('配置坚果云同步'));
    await _settle(tester);

    // 向导第一步（复用 /sync/guide 同一控件）。
    expect(find.text('开始配置'), findsOneWidget);
    expect(find.text('生成应用密码'), findsWidgets);
    // 向导同样在壳外：首启全程不冒出侧栏。
    expect(find.text('书库'), findsNothing);
    // 还没配完 → 首启未完成，标志不写。
    final stored = await tester.runAsync(
      () => env.db.appSettingsDao.getValue(OnboardingKeys.done),
    );
    expect(stored, isNull);
  });

  testWidgets('首启已完成：直接进书库，不再展示首启页', (tester) async {
    final env = await _setup(tester);

    onboardingGate.reset(OnboardingStatus.completed);
    await env.pump(tester);
    router.go('/');
    await _settle(tester);

    expect(find.text('书库为空'), findsOneWidget);
    expect(find.text('坚果云同步'), findsNothing);
  });
}

/// 读值必抛错的 DAO（模拟 app_settings 表不可用）。
class _BrokenAppSettingsDao extends AppSettingsDao {
  _BrokenAppSettingsDao(super.db);

  @override
  Future<String?> getValue(String key) async {
    throw StateError('app_settings 不可用');
  }
}

/// 测试环境：内存库 + 内存凭据 + 内存同步适配器 + 临时文件目录。
class _TestEnv {
  _TestEnv({required this.db, required this.tmp, required this.container});

  final AppDatabase db;
  final Directory tmp;
  final ProviderContainer container;

  /// 挂真 router + 真外壳路由（与 app_test 同款做法）。
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.light(AppAccent.terracotta),
          routerConfig: router,
        ),
      ),
    );
    await _settle(tester);
  }
}

/// 推进若干帧并放足时间。
///
/// **不用 pumpAndSettle**：书库加载态是无限循环的转圈动画，只要数据还没
/// 读回来就会一直有帧被调度，pumpAndSettle 永远不收敛。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

/// 建测试环境并登记收尾（关库、删临时目录、倒空定时器）。
Future<_TestEnv> _setup(WidgetTester tester) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  // 真实 IO（临时目录）必须在 runAsync 窗口内完成，否则 future 在
  // fakeAsync 区永不交付（同 app_test 的教训）。
  final tmpDir = await tester.runAsync(
    () => Directory.systemTemp.createTemp('onboarding_page_test'),
  );
  final tmp = tmpDir!;
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      bookFileStoreProvider.overrideWith((ref) async => BookFileStore(tmp)),
      secureCredentialStoreProvider.overrideWithValue(
        InMemoryCredentialStore(),
      ),
      syncAdapterProvider.overrideWithValue(
        const InMemorySyncAdapterProvider(),
      ),
    ],
  );
  // 收尾顺序与 settings_page_test 同款：卸载树 → 排空 drift 定时器 →
  // **先 dispose 容器**（断掉 watch 订阅）→ 再关库。顺序颠倒会挂住：
  // drift 关库要等所有订阅断干净，而订阅由容器持有。
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    container.dispose();
    await tester.runAsync(() async {
      await db.close();
      if (tmp.existsSync()) tmp.delete(recursive: true);
    });
  });
  return _TestEnv(db: db, tmp: tmp, container: container);
}
