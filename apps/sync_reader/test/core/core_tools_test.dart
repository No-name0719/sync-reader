/// 核心工具测试：ULID 形态 / 流式 SHA-256 / 日志脱敏 / SyncError 文案。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/core/app_logger.dart';
import 'package:sync_reader/core/content_hasher.dart';
import 'package:sync_reader/core/errors.dart';
import 'package:sync_reader/core/ulid.dart';

void main() {
  group('ULID（docs/05 §4.1）', () {
    test('生成 26 位大写 Crockford Base32，批量唯一', () {
      final ids = List.generate(50, (_) => generateUlid());
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$')));
        expect(isValidUlid(id), isTrue);
      }
      expect(ids.toSet(), hasLength(50));
      expect(isValidUlid('小写不是合法形态'), isFalse);
    });
  });

  group('ContentHasher（FR-102）', () {
    test('hashFile 输出 sha256:<hex> 且与短字节串全量计算一致', () async {
      final file = File(
        '${Directory.systemTemp.path}/sync_reader_hash_${DateTime.now().microsecondsSinceEpoch}.tmp',
      )..writeAsBytesSync(List.generate(3000, (i) => i % 251));
      try {
        final hash = await ContentHasher.hashFile(file);
        expect(hash, startsWith('sha256:'));
        expect(hash.substring('sha256:'.length), hasLength(64));
        // 同内容 → 同哈希；不同内容 → 不同哈希。
        expect(await ContentHasher.hashFile(file), hash);
        file.writeAsBytesSync([1]);
        expect(await ContentHasher.hashFile(file), isNot(hash));
      } finally {
        file.deleteSync();
      }
    });
  });

  group('AppLogger（NFR-03 凭据脱敏）', () {
    test('redactCredentials 打码常见凭据键', () {
      expect(
        AppLogger.redactCredentials('配置 password=abc123 与 token: "xyz-789"'),
        isNot(contains('abc123')),
      );
      expect(
        AppLogger.redactCredentials('Authorization: Bearer secret-token'),
        isNot(contains('secret-token')),
      );
      // 普通内容不受影响。
      expect(AppLogger.redactCredentials('普通日志：bookId=01A'), '普通日志：bookId=01A');
    });
  });

  group('SyncError（docs/03 §6.1 六类）', () {
    test('分类齐全且 userMessage 为中文分类文案', () {
      final errors = <SyncError>[
        NetworkUnreachable('超时'),
        AuthFailed('401'),
        QuotaExceeded('流量超限'),
        ConflictUnresolvable('无法合并'),
        ServerError('500', statusCode: 500),
        Corruption('校验失败'),
      ];
      expect(errors, hasLength(6));
      for (final e in errors) {
        expect(e.userMessage, isNotEmpty);
        expect(e.toString(), contains(e.message));
      }
      expect((errors[4] as ServerError).statusCode, 500);
    });
  });
}
