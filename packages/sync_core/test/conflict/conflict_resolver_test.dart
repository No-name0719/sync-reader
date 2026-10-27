import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// docs/04 §6 冲突合并规则 + §7.2 删除 vs 修改 全场景。
void main() {
  const resolver = ConflictResolver();
  const localDevice = '01DEVLOCAL0000000';

  BookMeta merge({
    required BookMeta local,
    required BookMeta remote,
    BookMeta? ancestor,
  }) => resolver.merge(
    local: local,
    remote: remote,
    ancestor: ancestor,
    deviceId: localDevice,
    deviceName: '测试机',
    now: t0,
  );

  group('docs/04 §6.2 三级决胜', () {
    test('第一级：rev 大者胜（胜者框架字段生效）', () {
      final local = buildMeta(
        bookId: bookIdOf(1),
        rev: 5,
        title: '本地胜',
        progress: buildProgress(percent: 0.9),
      );
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        title: '远端输',
        deviceId: '01DEVB',
        updatedAt: t0.add(const Duration(hours: 99)),
      );
      final merged = merge(local: local, remote: remote);
      expect(merged.book.title, '本地胜', reason: '框架字段全取胜者');
      expect(merged.progress?.percent, 0.9);
    });

    test('第二级：rev 相同比 updatedAt（大者胜）', () {
      final local = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        updatedAt: t0.add(const Duration(minutes: 10)),
        title: '本地旧',
        progress: buildProgress(
          percent: 0.2,
          updatedAt: t0.add(const Duration(minutes: 10)),
        ),
      );
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        updatedAt: t0.add(const Duration(minutes: 20)),
        deviceId: '01DEVB',
        title: '远端新',
        progress: buildProgress(
          percent: 0.8,
          updatedAt: t0.add(const Duration(minutes: 20)),
        ),
      );
      final merged = merge(local: local, remote: remote);
      expect(merged.book.title, '远端新', reason: 'updatedAt 更大者胜');
      expect(merged.progress?.percent, 0.8);
    });

    test('第三级：rev、updatedAt 均同比 deviceId 字典序（两端收敛一致）', () {
      final a = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        deviceId: '01DEVA',
        title: 'A 的版本',
        updatedAt: t0,
        progress: buildProgress(percent: 0.1),
      );
      final b = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        deviceId: '01DEVB',
        title: 'B 的版本',
        updatedAt: t0,
        progress: buildProgress(percent: 0.5),
      );
      // A 端视角与 B 端视角合并必须得出同一胜者（收敛性关键）。
      final fromA = resolver.merge(
        local: a,
        remote: b,
        deviceId: '01DEVA',
        deviceName: 'A',
        now: t0,
      );
      final fromB = resolver.merge(
        local: b,
        remote: a,
        deviceId: '01DEVB',
        deviceName: 'B',
        now: t0,
      );
      expect(fromA.book.title, 'B 的版本');
      expect(fromB.book.title, 'B 的版本', reason: 'deviceId 字典序大者胜，与视角无关');
      expect(fromA.progress?.percent, 0.5);
    });
  });

  group('docs/04 §6.3 合并算法字段特例', () {
    test('rev = max(local, remote) + 1；updatedAt/deviceId 取本机与 now', () {
      final local = buildMeta(bookId: bookIdOf(1), rev: 7);
      final remote = buildMeta(bookId: bookIdOf(1), rev: 4, deviceId: '01DEVB');
      final merged = merge(local: local, remote: remote);
      expect(merged.rev, 8);
      expect(merged.updatedAt, t0);
      expect(merged.deviceId, localDevice);
      expect(merged.deviceName, '测试机');
    });

    test('totalSeconds 求和扣除公共祖先：100 + 50 − 30 = 120', () {
      final ancestor = buildMeta(bookId: bookIdOf(1), rev: 2, totalSeconds: 30);
      final local = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        totalSeconds: 100,
        lastReadAt: t0.add(const Duration(hours: 2)),
      );
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 4,
        deviceId: '01DEVB',
        totalSeconds: 50,
      );
      final merged = merge(local: local, remote: remote, ancestor: ancestor);
      expect(merged.reading.totalSeconds, 120);
    });

    test('公共祖先缺失 → 退化为直接求和（重装场景，docs/04 §6.3 实现注）', () {
      final local = buildMeta(bookId: bookIdOf(1), rev: 3, totalSeconds: 100);
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 4,
        deviceId: '01DEVB',
        totalSeconds: 50,
      );
      final merged = merge(local: local, remote: remote);
      expect(merged.reading.totalSeconds, 150);
    });

    test('lastReadAt 取两端最大值', () {
      final local = buildMeta(
        bookId: bookIdOf(1),
        rev: 3,
        lastReadAt: t0.add(const Duration(hours: 2)),
      );
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 4,
        deviceId: '01DEVB',
        lastReadAt: t0.add(const Duration(hours: 5)),
      );
      final merged = merge(local: local, remote: remote);
      expect(merged.reading.lastReadAt, t0.add(const Duration(hours: 5)));
    });

    test('扣除后为负 → clamp ≥ 0', () {
      final ancestor = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        totalSeconds: 100,
      );
      final local = buildMeta(bookId: bookIdOf(1), rev: 3, totalSeconds: 20);
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 4,
        deviceId: '01DEVB',
        totalSeconds: 30,
      );
      final merged = merge(local: local, remote: remote, ancestor: ancestor);
      expect(merged.reading.totalSeconds, 0);
    });
  });

  group('docs/04 §6.4 典型冲突场景验收', () {
    test('A 端 40% / B 端 75%：B 的 updatedAt 更大 → 两端收敛到 75%', () {
      final a = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVA',
        progress: buildProgress(
          percent: 0.40,
          updatedAt: t0.add(const Duration(minutes: 5)),
        ),
      );
      final b = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB',
        progress: buildProgress(
          percent: 0.75,
          updatedAt: t0.add(const Duration(minutes: 15)),
        ),
      );
      final mergedAtA = resolver.merge(
        local: a,
        remote: b,
        deviceId: '01DEVA',
        deviceName: 'A',
        now: t0,
      );
      expect(mergedAtA.progress?.percent, 0.75);
    });

    test('A 端进度更新与 B 端书名修正并发：胜者整框架生效（书名修正丢失，v1 接受）', () {
      final progressSide = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        title: '旧书名',
        updatedAt: t0.add(const Duration(minutes: 30)),
        progress: buildProgress(
          percent: 0.9,
          updatedAt: t0.add(const Duration(minutes: 30)),
        ),
      );
      final renameSide = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB',
        title: '修正后的书名',
        updatedAt: t0.add(const Duration(minutes: 1)),
        progress: buildProgress(
          percent: 0.3,
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      final merged = merge(local: progressSide, remote: renameSide);
      expect(merged.book.title, '旧书名', reason: '胜者是进度端，书名修正并发丢失（docs/07-Q7）');
      expect(merged.progress?.percent, 0.9);
    });

    test('双端 totalSeconds 各 +30min → 合并 +60min', () {
      final ancestor = buildMeta(bookId: bookIdOf(1), rev: 1, totalSeconds: 60);
      final local = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        totalSeconds: 60 + 30,
      );
      final remote = buildMeta(
        bookId: bookIdOf(1),
        rev: 2,
        deviceId: '01DEVB',
        totalSeconds: 60 + 30,
      );
      final merged = merge(local: local, remote: remote, ancestor: ancestor);
      expect(merged.reading.totalSeconds, 60 + 60);
    });
  });

  group('docs/04 §7.2 删除 vs 修改（tombstone 与正常 meta 同一定序）', () {
    // base 带 30% 进度：tombstone 保留 progress（docs/05 §2），供审计与重关联。
    final n = 5;

    test(
      '行 1：A 删除（tombstone rev=n+1，updatedAt 更晚） vs B 进度更新（rev=n+1） → 删除胜',
      () {
        // 删除操作与正常修改一致：tombstone 写入时 updatedAt 前移（LWW 第二位可比）。
        final tomb = buildMeta(
          bookId: bookIdOf(1),
          rev: n + 1,
          deviceId: '01DEVA',
          deleted: true,
          deletedAt: t0.add(const Duration(minutes: 20)),
          updatedAt: t0.add(const Duration(minutes: 20)),
          progress: buildProgress(percent: 0.3),
        );
        // B 的进度更新 rev=n+1、updatedAt 更早。
        final progressUpdate = buildMeta(
          bookId: bookIdOf(1),
          rev: n + 1,
          deviceId: '01DEVB',
          updatedAt: t0.add(const Duration(minutes: 10)),
          progress: buildProgress(
            percent: 0.6,
            updatedAt: t0.add(const Duration(minutes: 10)),
          ),
        );
        final merged = merge(local: progressUpdate, remote: tomb);
        expect(merged.deleted, isTrue, reason: '删除胜：B 的进度更新被丢弃');
        expect(merged.deletedAt, tomb.deletedAt);
        expect(
          merged.progress?.percent,
          0.3,
          reason: '胜者是 tombstone，框架字段全取 tombstone',
        );
      },
    );

    test('行 2：B 进度更新 updatedAt 更晚且 rev 相等 → B 胜，删除被"复活"（deleted=false）', () {
      final tomb = buildMeta(
        bookId: bookIdOf(1),
        rev: n + 1,
        deviceId: '01DEVA',
        deleted: true,
        deletedAt: t0.add(const Duration(minutes: 1)),
        updatedAt: t0.add(const Duration(minutes: 1)),
      );
      final progressUpdate = buildMeta(
        bookId: bookIdOf(1),
        rev: n + 1,
        deviceId: '01DEVB',
        updatedAt: t0.add(const Duration(minutes: 30)),
        progress: buildProgress(
          percent: 0.6,
          updatedAt: t0.add(const Duration(minutes: 30)),
        ),
      );
      final merged = merge(local: progressUpdate, remote: tomb);
      expect(
        merged.deleted,
        isFalse,
        reason: 'rev 更高的正常 meta 复活（docs/05 §6 不变式 2）',
      );
      expect(merged.rev, greaterThan(tomb.rev));
      expect(merged.progress?.percent, 0.6);
    });

    test('行 3：双端都删除 → 幂等收敛为 tombstone', () {
      final tombA = buildMeta(
        bookId: bookIdOf(1),
        rev: n + 1,
        deviceId: '01DEVA',
        deleted: true,
        deletedAt: t0.add(const Duration(minutes: 5)),
        updatedAt: t0.add(const Duration(minutes: 5)),
      );
      final tombB = buildMeta(
        bookId: bookIdOf(1),
        rev: n + 1,
        deviceId: '01DEVB',
        deleted: true,
        deletedAt: t0.add(const Duration(minutes: 3)),
        updatedAt: t0.add(const Duration(minutes: 3)),
      );
      final merged = merge(local: tombA, remote: tombB);
      expect(merged.deleted, isTrue);
      expect(merged.rev, n + 2, reason: 'max(A,B)+1 继续单调');
      expect(merged.deviceId, localDevice, reason: '合并结果由本机作为新写端');
    });
  });
}
