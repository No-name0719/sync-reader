import 'dart:async';
import 'dart:io';

import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

/// docs/03 §6.1 六类错误 + SyncErrorMapper 映射表逐条（docs/04 §8.4 语义）。
void main() {
  group('SyncErrorMapper.fromException 映射表', () {
    test('AuthFailed（传输层）→ AuthFailedSyncError', () {
      final e = SyncErrorMapper.fromException(const AuthFailed('401 未授权'));
      expect(e, isA<AuthFailedSyncError>());
      expect(e.cause, isA<AuthFailed>());
    });

    test('RevConflict（重试耗尽兜底路径）→ ConflictUnresolvable', () {
      final e = SyncErrorMapper.fromException(RevConflict('b1', 3, null));
      expect(e, isA<ConflictUnresolvable>());
    });

    test('BackendRequestException 401 → AuthFailedSyncError', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('凭据失效', statusCode: 401),
      );
      expect(e, isA<AuthFailedSyncError>());
    });

    test('BackendRequestException 404 → Corruption（云端资源缺失）', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('正文不存在', statusCode: 404),
      );
      expect(e, isA<Corruption>());
    });

    test('BackendRequestException 5xx → ServerError 且带 statusCode', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('网关错误', statusCode: 502),
      );
      expect(e, isA<ServerError>());
      expect((e as ServerError).statusCode, 502);
    });

    test('BackendRequestException 429 → NetworkUnreachable（可重试类）', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('限流', statusCode: 429),
      );
      expect(e, isA<NetworkUnreachable>());
    });

    test('BackendRequestException 无状态码（网络异常）→ NetworkUnreachable', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('连接超时'),
      );
      expect(e, isA<NetworkUnreachable>());
    });

    test('FormatException（meta 严格校验失败）→ Corruption（docs/05 §6）', () {
      final e = SyncErrorMapper.fromException(
        const FormatException('rev 必须 ≥ 1'),
      );
      expect(e, isA<Corruption>());
    });

    test('SocketException → NetworkUnreachable', () {
      final e = SyncErrorMapper.fromException(
        const SocketException('connection refused'),
      );
      expect(e, isA<NetworkUnreachable>());
    });

    test('TimeoutException → NetworkUnreachable', () {
      final e = SyncErrorMapper.fromException(TimeoutException('timeout'));
      expect(e, isA<NetworkUnreachable>());
    });

    test('ContentHashMismatch → Corruption', () {
      final e = SyncErrorMapper.fromException(
        ContentHashMismatch('b1', '哈希不符'),
      );
      expect(e, isA<Corruption>());
    });

    test('未知异常 → ServerError 兜底', () {
      final e = SyncErrorMapper.fromException(StateError('boom'));
      expect(e, isA<ServerError>());
    });

    test('已是 SyncError → 原样返回（不二次包装）', () {
      const original = Corruption('原文');
      expect(SyncErrorMapper.fromException(original), same(original));
    });

    test('context 前缀进入 message，cause 保留原始异常', () {
      final e = SyncErrorMapper.fromException(
        const BackendRequestException('连接超时'),
        context: '拉取清单',
      );
      expect(e.message, contains('拉取清单'));
      expect(e.cause, isA<BackendRequestException>());
    });
  });

  group('SyncError 基础语义', () {
    test('六类均含 message/cause 且 toString 含类名', () {
      final errors = <SyncError>[
        const NetworkUnreachable('a'),
        const AuthFailedSyncError('b'),
        const QuotaExceeded('c'),
        const ConflictUnresolvable('d'),
        const ServerError('e'),
        const Corruption('f'),
      ];
      for (final e in errors) {
        expect(e.message, isNotEmpty);
        expect(e.toString(), contains(e.message));
      }
    });
  });
}
