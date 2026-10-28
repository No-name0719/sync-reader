/// AppLogger 环形缓冲测试（FR-604）：
/// 容量淘汰、snapshot 副本性、clear、分级落缓冲、enabled 语义。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/app_logger.dart';

void main() {
  setUp(() {
    // 缓冲为全实例共享静态状态，逐用例清空保证隔离。
    AppLogger.clear();
  });

  group('AppLogger 环形缓冲（FR-604）', () {
    test('容量淘汰：超过 2000 行后保留最新的 2000 行，最旧被淘汰', () {
      final log = AppLogger();
      const total = AppLogger.defaultBufferCapacity + 50;
      for (var i = 0; i < total; i++) {
        log.info('line-$i');
      }
      final snap = AppLogger.snapshot();
      expect(snap, hasLength(AppLogger.defaultBufferCapacity));
      // 最旧的 line-0..line-49 被淘汰，首行为 line-50，末行为最后一条。
      expect(snap.first, endsWith('line-50'));
      expect(snap.last, endsWith('line-${total - 1}'));
      expect(snap.first, isNot(contains('line-49')));
    });

    test('snapshot 返回副本：改动副本不影响缓冲本身', () {
      AppLogger().info('keep-me');
      final copy = AppLogger.snapshot();
      copy.clear();
      copy.add('polluted');
      final again = AppLogger.snapshot();
      expect(again, hasLength(1));
      expect(again.single, endsWith('keep-me'));
    });

    test('clear 清空缓冲', () {
      final log = AppLogger();
      log.info('before-1');
      log.warn('before-2');
      expect(AppLogger.snapshot(), isNotEmpty);
      AppLogger.clear();
      expect(AppLogger.snapshot(), isEmpty);
    });

    test('info/warn/error 都落缓冲，且带时间戳与级别前缀（与 debugPrint 一致）', () {
      final log = AppLogger();
      log.info('信息行');
      log.warn('警告行');
      log.error('错误行');
      final snap = AppLogger.snapshot();
      expect(snap, hasLength(3));
      expect(
        snap[0],
        matches(RegExp(r'^\[\d{4}-\d{2}-\d{2}T[\d:.]+\]\[INFO\] 信息行$')),
      );
      expect(snap[1], contains('[WARN] 警告行'));
      expect(snap[2], contains('[ERROR] 错误行'));
    });

    test('enabled: true 实例写入缓冲（release 可导出的行为由默认值保证）', () {
      // 注：测试环境 kDebugMode 恒为 true，无法真正模拟 kReleaseMode；
      // release 行为等价于"默认 enabled 恒 true"，故直接构造
      // enabled: true 实例验证写入路径，构造默认值即 release 下的取值。
      final logger = AppLogger(enabled: true);
      logger.info('release-语义行');
      expect(AppLogger.snapshot().single, contains('release-语义行'));
    });

    test('enabled: false 静音（测试隔离用）：不输出也不进缓冲', () {
      AppLogger(enabled: false).info('不应出现');
      expect(AppLogger.snapshot(), isEmpty);
    });

    test('minLevel 过滤在进缓冲前生效', () {
      AppLogger(minLevel: LogLevel.warn)
        ..info('被丢弃的 info')
        ..warn('留下的 warn');
      final snap = AppLogger.snapshot();
      expect(snap, hasLength(1));
      expect(snap.single, contains('留下的 warn'));
    });
  });
}
