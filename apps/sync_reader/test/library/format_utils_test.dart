/// 展示层格式化工具单测（lib/shared/format_utils.dart）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/shared/format_utils.dart';

void main() {
  group('humanizeBytes', () {
    test('各量级', () {
      expect(humanizeBytes(0), '0 B');
      expect(humanizeBytes(980), '980 B');
      expect(humanizeBytes(1024), '1.00 KB');
      expect(humanizeBytes(1536), '1.50 KB');
      expect(humanizeBytes(1048576), '1.00 MB');
      expect(humanizeBytes(12 * 1024 * 1024), '12.0 MB');
      expect(humanizeBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
    test('非法输入', () => expect(humanizeBytes(-1), '-'));
  });

  group('humanizeDuration', () {
    test('秒/分/时/天', () {
      expect(humanizeDuration(0), '0 秒');
      expect(humanizeDuration(42), '42 秒');
      expect(humanizeDuration(60), '1 分钟');
      expect(humanizeDuration(35 * 60), '35 分钟');
      expect(humanizeDuration(3 * 3600 + 12 * 60), '3 小时 12 分钟');
      expect(humanizeDuration(2 * 3600), '2 小时');
      expect(humanizeDuration(23 * 3600), '23 小时'); // 未满 1 天
      expect(humanizeDuration(30 * 3600), '1 天 6 小时');
    });
    test('非法输入', () => expect(humanizeDuration(-5), '-'));
  });

  group('formatEpochMs', () {
    test('正常与空值', () {
      final ms = DateTime(2026, 10, 26, 8, 30).millisecondsSinceEpoch;
      expect(formatEpochMs(ms), '2026-10-26 08:30');
      expect(formatEpochMs(null), '-');
      expect(formatEpochMs(0), '-');
    });
  });

  group('formatPercent', () {
    test('比例转百分比并钳制', () {
      expect(formatPercent(0), '0%');
      expect(formatPercent(0.42), '42%');
      expect(formatPercent(0.425), '43%'); // 四舍五入
      expect(formatPercent(1), '100%');
      expect(formatPercent(1.5), '100%');
      expect(formatPercent(-0.2), '0%');
    });
  });

  group('shortenHash', () {
    test('sha256 前缀保留 + 前 8 hex', () {
      expect(shortenHash('sha256:0123456789abcdef'), 'sha256:01234567…');
      expect(shortenHash('sha256:ab'), 'sha256:ab');
      expect(shortenHash('plainhash123456'), 'plainhas…');
      expect(shortenHash('short'), 'short');
    });
  });
}
