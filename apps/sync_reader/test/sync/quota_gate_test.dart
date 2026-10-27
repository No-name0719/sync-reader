/// 配额闸门测试（docs/04 §8.3 / FR-407）：
/// 80% 告警 / 100% 挂起边界、跨月重置、越权放行、TransferQueue 埋点。
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_core/sync_core.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/data/sync/drift_sync_store.dart';
import 'package:sync_reader/features/sync/quota_gate.dart';

void main() {
  late AppDatabase db;
  late DriftSyncStore store;
  late SyncQuotaGate gate;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    store = DriftSyncStore(
      db: db,
      credentials: InMemoryCredentialStore(),
      backendKey: 'webdav',
    );
    gate = SyncQuotaGate(store: store);
  });

  tearDown(() async => db.close());

  group('decide（纯决策）', () {
    test('额度内放行', () {
      expect(
        SyncQuotaGate.decide(downBytes: 100, estBytes: 50, override: false),
        isTrue,
      );
    });

    test('达到 100% 挂起：已用 + 估算超限即拒绝', () {
      expect(
        SyncQuotaGate.decide(
          downBytes: QuotaLimits.downLimitBytes,
          estBytes: 0,
          override: false,
        ),
        isFalse,
      );
      expect(
        SyncQuotaGate.decide(
          downBytes: QuotaLimits.downLimitBytes - 10,
          estBytes: 11,
          override: false,
        ),
        isFalse,
      );
      // 恰好不超限 → 放行。
      expect(
        SyncQuotaGate.decide(
          downBytes: QuotaLimits.downLimitBytes - 10,
          estBytes: 10,
          override: false,
        ),
        isTrue,
      );
    });

    test('越权放行：override 恒 true（二次确认由 UI 层做）', () {
      expect(
        SyncQuotaGate.decide(
          downBytes: QuotaLimits.downLimitBytes * 2,
          estBytes: 999,
          override: true,
        ),
        isTrue,
      );
    });
  });

  group('告警阈值（FR-407：上行 800MB / 下行 2.4GB ≈ 80%）', () {
    test('warn 阈值常量与比例语义', () {
      expect(QuotaLimits.upLimitBytes, 1024 * 1024 * 1024);
      expect(QuotaLimits.downLimitBytes, 3 * 1024 * 1024 * 1024);
      expect(QuotaLimits.warnRatio, 0.8);
      // 80% 边界：恰好达到告警线即告警。
      final atWarn = QuotaSnapshot(
        upBytes: QuotaLimits.upWarnBytes,
        downBytes: 0,
      );
      expect(atWarn.warn, isTrue);
      final below = QuotaSnapshot(
        upBytes: QuotaLimits.upWarnBytes - 1,
        downBytes: 0,
      );
      expect(below.warn, isFalse);
    });

    test('downExceeded：下行达 100%', () {
      expect(
        QuotaSnapshot(
          upBytes: 0,
          downBytes: QuotaLimits.downLimitBytes,
        ).downExceeded,
        isTrue,
      );
      expect(QuotaSnapshot(upBytes: 0, downBytes: 1024).downExceeded, isFalse);
    });

    test('warnText 文案分级：超限 / 80% 告警 / 无', () {
      expect(
        SyncQuotaGate.warnText(const QuotaSnapshot(upBytes: 1, downBytes: 1)),
        isNull,
      );
      expect(
        SyncQuotaGate.warnText(
          QuotaSnapshot(upBytes: QuotaLimits.upWarnBytes, downBytes: 0),
        ),
        contains('80%'),
      );
      expect(
        SyncQuotaGate.warnText(
          QuotaSnapshot(upBytes: 0, downBytes: QuotaLimits.downLimitBytes),
        ),
        contains('上限'),
      );
    });
  });

  group('record / refresh（持久化 + 缓存）', () {
    test('record 累加并更新缓存；refresh 从持久层装载', () async {
      final now = DateTime(2026, 10, 15);
      await gate.record(100, 200, now: now);
      expect(gate.snapshot.upBytes, 100);
      expect(gate.snapshot.downBytes, 200);
      // 模拟缓存丢失：新建闸门并 refresh。
      final gate2 = SyncQuotaGate(store: store);
      expect(gate2.snapshot.downBytes, 0);
      final loaded = await gate2.refresh(now: now);
      expect(loaded.downBytes, 200);
      expect(gate2.snapshot.downBytes, 200);
    });

    test('跨月：record 按当前月清零重计', () async {
      await gate.record(1000, 2000, now: DateTime(2026, 9, 30));
      await gate.record(1, 2, now: DateTime(2026, 10, 1));
      expect(gate.snapshot.upBytes, 1);
      expect(gate.snapshot.downBytes, 2);
      expect(gate.snapshot.month, '2026-10');
    });

    test('refresh 对旧月数据兜底清零', () async {
      await store.saveCursorSnapshot(
        BackendCursorSnapshot(
          backendKey: 'webdav',
          quotaUpBytes: 999,
          quotaDownBytes: QuotaLimits.downLimitBytes,
          quotaMonth: '2025-01',
        ),
      );
      final snap = await gate.refresh(now: DateTime(2026, 10, 15));
      expect(snap.upBytes, 0);
      expect(snap.downBytes, 0);
      expect(gate.allowDownload(1), isTrue);
    });
  });

  group('allowDownload（TransferQueue 钩子路径）', () {
    test('缓存驱动：100% 后拒绝、越权后放行', () async {
      await gate.record(0, QuotaLimits.downLimitBytes, now: DateTime(2026, 10));
      expect(gate.allowDownload(1), isFalse);
      expect(gate.allowDownload(1, override: true), isTrue);
    });

    test('resetCache 后回到空快照', () async {
      await gate.record(10, 10, now: DateTime(2026, 10));
      gate.resetCache();
      expect(gate.snapshot.upBytes, 0);
      expect(gate.allowDownload(1), isTrue);
    });
  });

  group('TransferQueue.onBytes 埋点（docs/04 §8.3）', () {
    test('上传/下载字节经 onBytes 写入持久层', () async {
      await gate.refresh();
      final transfer = TransferQueue(
        adapter: InMemoryAdapter(),
        retryPolicy: const RetryPolicy(),
        onBytes: (direction, bytes) {
          final up = direction == TransferDirection.upload ? bytes : 0;
          final down = direction == TransferDirection.download ? bytes : 0;
          unawaited(gate.record(up, down));
        },
      );
      // 直接驱动计量钩子（传输本身由 sync_core 契约测试覆盖）。
      transfer.onBytes?.call(TransferDirection.upload, 77);
      transfer.onBytes?.call(TransferDirection.download, 88);
      await Future<void>.delayed(Duration.zero);
      final snap = await store.cursorSnapshot('webdav');
      expect(snap.quotaUpBytes, 77);
      expect(snap.quotaDownBytes, 88);
    });
  });
}
