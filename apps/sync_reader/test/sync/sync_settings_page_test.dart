/// 同步设置页 widget 测试（FR-405/406/409/505 + A12 分区布局关键路径）：
/// 未配置态 → 引导入口；开关持久化（reader_settings `sync.preferences`）；
/// 失败原因文案显示；配额面板告警；分区顺序/存在性；危险区红样式；
/// 「云端孤儿清理」入口不再出现（Q16）；云端书库卡未配置降级。
///
/// v1.1 A12 选择器更新记录（语义不变）：
/// - 未配置态「后端未配置」→ 后端卡状态胶囊「未配置」（+「去配置」保留）；
/// - 分区改为卡片化（原型同步屏），新增分区顺序/存在性断言；
/// - 配额越权从面板内按钮改为第三条开关行（二次确认语义保留）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/core/design_tokens.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/sync_settings_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_preferences.dart';
import 'package:sync_reader/features/sync/sync_status.dart';

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
        syncAdapterProvider.overrideWithValue(
          const _UnconfiguredAdapterProvider(),
        ),
      ],
    );
    // 页面 watch 了 drift 流（书数 / 仅本地的书）：关库收尾需先注册
    // （addTearDown LIFO → 最后执行），让 container.dispose 先取消流订阅；
    // 再排空 drift 定时器并在真实区关库（与 orphan_files_page_test 一致，
    // 顺序颠倒会让 db.close 挂起）。
    addTearDown(() async {
      await tester.pump(const Duration(minutes: 1));
      await tester.runAsync(db.close);
    });
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(AppAccent.terracotta),
          home: const SyncSettingsPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  setUp(() {
    credentials = InMemoryCredentialStore();
  });

  Future<void> seedCredentials() async {
    await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
    await credentials.save(SecureKeys.webdavPassword, 'app-secret');
    await credentials.save(
      SecureKeys.webdavBaseUrl,
      'https://dav.example.com/',
    );
    await credentials.save(SecureKeys.webdavRootPath, '/Apps/SyncReader');
  }

  testWidgets('未配置态：后端卡状态胶囊「未配置」+ 去配置入口；云端书库卡降级', (tester) async {
    await pumpPage(tester);
    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
    // 云端书库卡：未配置 → 数量降级为引导文案（不显示计数）。
    expect(find.text('配置同步后可管理云端书籍'), findsOneWidget);
    expect(find.text('— 本'), findsNothing);
  });

  testWidgets('已配置态：显示坚果云 WebDAV + 账号 + 已连接胶囊', (tester) async {
    await seedCredentials();
    await pumpPage(tester);
    expect(find.text('坚果云 WebDAV'), findsOneWidget);
    expect(find.textContaining('user@example.com'), findsOneWidget);
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('自动同步开关切换即持久化（sync.preferences JSON）', (tester) async {
    final container = await pumpPage(tester);
    final initial = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(initial, isNull); // 未动过。

    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pump();
    final stored = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(stored, isNotNull);
    expect(stored, contains('"autoSyncEnabled":false'));
    // 状态同步更新。
    expect(container.read(syncPreferencesProvider).autoSyncEnabled, isFalse);
  });

  testWidgets('仅 Wi-Fi 正文开关切换持久化', (tester) async {
    await pumpPage(tester);
    // 第二个开关是"仅 Wi-Fi 下载正文"。
    await tester.tap(find.byType(SwitchListTile).at(1));
    await tester.pump();
    final stored = await db.readerSettingsDao.getValue(
      SyncPreferencesNotifier.storageKey,
    );
    expect(stored, contains('"wifiOnlyContent":false'));
  });

  testWidgets('配额越权开关：开启需二次确认，取消不生效', (tester) async {
    final container = await pumpPage(tester);
    // 第三个开关是"配额越权"。
    await tester.tap(find.byType(SwitchListTile).at(2));
    await tester.pumpAndSettle();
    expect(find.text('本月流量已达上限'), findsOneWidget);
    // 取消 → 不越权。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(container.read(syncPreferencesProvider).quotaOverride, isFalse);
  });

  testWidgets('同步失败：失败原因分类文案可见（FR-406）', (tester) async {
    final container = await pumpPage(tester);
    container
        .read(syncMemoryStatusProvider.notifier)
        .applyOutcome(
          const SyncStatusOutcome(
            stateId: SyncStateId.failed,
            failureText: '密码错误或账号失效，请重新配置',
          ),
        );
    await tester.pump();
    expect(find.textContaining('密码错误或账号失效'), findsOneWidget);
    // 立即同步按钮在失败后仍可用（可重试）。
    expect(find.text('立即同步'), findsWidgets);
  });

  testWidgets('同步中：按钮禁用并显示进行中指示', (tester) async {
    final container = await pumpPage(tester);
    container.read(syncMemoryStatusProvider.notifier).markSyncing();
    await tester.pump();
    final button = tester.widget<FilledButton>(
      find.ancestor(of: find.text('立即同步'), matching: find.byType(FilledButton)),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('配额面板：内存侧告警文案可见（80% 常驻提醒）', (tester) async {
    final container = await pumpPage(tester);
    container
        .read(syncMemoryStatusProvider.notifier)
        .setQuotaWarn('本月同步流量已超过 80%，自动下载已放缓');
    await tester.pump();
    expect(find.textContaining('80%'), findsWidgets);
  });

  testWidgets('维护区：导出诊断日志与清空日志入口可见（FR-604）', (tester) async {
    await pumpPage(tester);
    expect(find.text('导出诊断日志'), findsOneWidget);
    expect(find.text('清空日志'), findsOneWidget);
    expect(find.textContaining('二次脱敏'), findsOneWidget);
  });

  testWidgets('分区顺序：后端 → 立即同步/开关 → 流量 → 未上传的书 → 云端书库 → 维护 → 危险区', (
    tester,
  ) async {
    await pumpPage(tester);
    // 存在性：八分区锚点全部可见。
    expect(find.text('坚果云 WebDAV'), findsOneWidget);
    expect(find.text('立即同步'), findsWidgets);
    expect(find.text('自动同步'), findsOneWidget);
    expect(find.text('本月流量'), findsOneWidget);
    expect(find.text('未上传的书'), findsOneWidget);
    expect(find.text('云端书库'), findsOneWidget);
    expect(find.text('维护'), findsOneWidget);
    expect(find.text('危险操作'), findsOneWidget);

    // 渲染顺序：自上而下严格递增。
    double dyOf(String text) => tester.getTopLeft(find.text(text).first).dy;
    final dys = <double>[
      dyOf('坚果云 WebDAV'),
      dyOf('自动同步'),
      dyOf('本月流量'),
      dyOf('未上传的书'),
      dyOf('云端书库'),
      dyOf('维护'),
      dyOf('危险操作'),
    ];
    for (var i = 1; i < dys.length; i++) {
      expect(dys[i], greaterThan(dys[i - 1]), reason: '分区 $i 应在分区 ${i - 1} 下方');
    }
  });

  testWidgets('「云端孤儿清理」入口不再出现（Q16）；「测试连接」唯一化在后端卡', (tester) async {
    await pumpPage(tester);
    expect(find.text('云端孤儿清理'), findsNothing);
    // v1.1：「测试连接」点一下即测已保存配置，就地出结果；维护区原有的同名
    // 入口（跳转向导）功能重复且行为不一致，已移除——页面里应只剩一处。
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('往返延迟与目录权限检查'), findsNothing);
    // 维护区仍保留导出诊断日志。
    expect(find.text('导出诊断日志'), findsOneWidget);
  });

  testWidgets('危险区红样式：标题与「清除凭据」用 danger 令牌（红描边卡）', (tester) async {
    await pumpPage(tester);
    final tokens = tester.element(find.text('危险操作')).appTokens;
    // 卡头标题红字。
    final title = tester.widget<Text>(find.text('危险操作'));
    expect(title.style!.color, tokens.danger);
    // 行标题红字 + 清除按钮红色描边。
    final rowTitle = tester.widget<Text>(find.text('清除凭据'));
    expect(rowTitle.style!.color, tokens.danger);
    final clearButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '清除'),
    );
    expect(clearButton.style?.side?.resolve(const {}), isNotNull);
    expect(clearButton.style!.side!.resolve(const {})!.color, tokens.danger);
  });
}

/// 未配置适配器（设置页测试不需要真实引擎）。
class _UnconfiguredAdapterProvider implements SyncAdapterProvider {
  const _UnconfiguredAdapterProvider();

  @override
  BackendAdapter create(BackendConfig config) =>
      throw UnimplementedError('测试不应构建适配器');
}
