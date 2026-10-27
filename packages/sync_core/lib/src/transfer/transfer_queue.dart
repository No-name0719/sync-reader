import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';

import '../backend/backend_adapter.dart';
import '../internal/semaphore.dart';
import '../model/sync_error.dart';

/// 传输方向（字节计量用）。
enum TransferDirection { download, upload }

/// 字节计量钩子：下载/上传各计一次（供配额闸门埋点，docs/04 §8.3）。
typedef OnBytes = void Function(TransferDirection direction, int bytes);

/// 配额闸门挂钩：返回 false 则下载挂起（docs/04 §8.3，仅约束正文下载；
/// 上传与元数据不受限的语义由引擎保证，队列只管正文）。
typedef QuotaGate = bool Function(int estimatedBytes);

/// 重试策略参数（docs/04 §8.4 全表的可配置形态）。
class RetryPolicy {
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 300),
    this.maxNetworkAttempts = 5,
    this.maxServerRetries = 3,
    this.maxRateLimitAttempts = 5,
    this.rateLimitFallback = const Duration(seconds: 60),
    this.jitterRatio = 0.2,
    this.maxHashAttempts = 2,
  });

  /// 指数退避基数（第 n 次失败 → baseDelay × 2^(n-1)）。
  final Duration baseDelay;

  /// 退避上限。
  final Duration maxDelay;

  /// 连续网络失败放弃阈值：第 5 次失败即本轮放弃回 Idle。
  final int maxNetworkAttempts;

  /// 5xx 重试上限（不含首次）。
  final int maxServerRetries;

  /// 429/503 限流重试上限（docs 未封顶，实现保守封顶防挂死）。
  final int maxRateLimitAttempts;

  /// 429/503 无 `Retry-After` 头时的固定等待。
  final Duration rateLimitFallback;

  /// 抖动比例 ±20%。
  final double jitterRatio;

  /// 下载哈希校验失败"删除重来"次数上限（docs/04 §5.4：最多 2 次）。
  final int maxHashAttempts;
}

/// 传输队列（docs/04 §8）：并发上限（下载 2 / 上传 1）、指数退避重试、
/// 字节计量、断点续传与下载哈希校验。
///
/// 只负责正文传输；meta 的读写由引擎直接驱动（冲突合并路径不进队列，
/// [RevConflict] / [AuthFailed] 原样上抛）。
class TransferQueue {
  TransferQueue({
    required BackendAdapter adapter,
    this.downloadConcurrency = 2,
    this.uploadConcurrency = 1,
    required this.retryPolicy,
    Random? jitterRandom,
    DateTime Function()? clock,
    Future<void> Function(Duration delay)? delay,
    this.onBytes,
    this.quotaGate,
  }) : _adapter = adapter,
       _jitterRandom = jitterRandom ?? Random(20261026),
       clock = clock ?? DateTime.now,
       _delay = delay ?? ((d) => Future<void>.delayed(d)),
       _downloadSlots = Semaphore(downloadConcurrency),
       _uploadSlots = Semaphore(uploadConcurrency);

  final BackendAdapter _adapter;

  /// 下载并发上限（默认 2，docs/03 §4.3）。
  final int downloadConcurrency;

  /// 上传并发上限（默认 1）。
  final int uploadConcurrency;

  final RetryPolicy retryPolicy;

  /// 抖动随机源（注入保证可测：固定 seed → 确定性延迟）。
  final Random _jitterRandom;

  /// 时钟（注入保证可测；预留重试记账/诊断）。
  final DateTime Function() clock;

  /// 等待函数（注入使测试不真等）。
  final Future<void> Function(Duration delay) _delay;

  /// 字节计量钩子（可随时替换/置 null）。
  OnBytes? onBytes;

  /// 附加计量监听（引擎按次同步注册/注销，与 [onBytes] 并存）。
  final List<OnBytes> _bytesListeners = [];

  void addBytesListener(OnBytes listener) => _bytesListeners.add(listener);

  void removeBytesListener(OnBytes listener) {
    _bytesListeners.remove(listener);
  }

  /// 可选配额闸门：拒绝时下载抛 [QuotaExceeded] 挂起。
  final QuotaGate? quotaGate;

  final Semaphore _downloadSlots;
  final Semaphore _uploadSlots;

  /// 累计字节（download/upload 两向，测试与诊断用）。
  final Map<TransferDirection, int> bytesByDirection = {
    TransferDirection.download: 0,
    TransferDirection.upload: 0,
  };

  int get activeDownloads => _downloadSlots.active;
  int get peakDownloads => _downloadSlots.peak;
  int get activeUploads => _uploadSlots.active;
  int get peakUploads => _uploadSlots.peak;

  /// 下载正文到 [targetPath]：写 `.part`、中断后续传（Range: 已有长度-）、
  /// 完成后校验 SHA-256 → rename 转正（docs/04 §5.4 / §8.2）。
  ///
  /// 哈希（或尺寸）不符 → 删除 `.part` 重来，重试 [RetryPolicy.maxHashAttempts]
  /// 次后抛 [Corruption]；网络/服务端错误按 §8.4 重试策略处理。
  Future<void> downloadToFile(
    String bookId, {
    required String targetPath,
    required String partPath,
    String? expectedHash,
    int? expectedSize,
  }) {
    return _downloadSlots.run(
      () => _downloadLocked(
        bookId,
        targetPath: targetPath,
        partPath: partPath,
        expectedHash: expectedHash,
        expectedSize: expectedSize,
      ),
    );
  }

  Future<void> _downloadLocked(
    String bookId, {
    required String targetPath,
    required String partPath,
    required String? expectedHash,
    required int? expectedSize,
  }) async {
    var verifyFailures = 0;
    while (true) {
      final part = File(partPath);
      final partLength = await part.exists() ? await part.length() : 0;
      final haveAll = expectedSize != null && partLength >= expectedSize;

      // 配额闸门：按剩余字节估算（未知大小按 0 估算放行）。
      if (!haveAll && quotaGate != null) {
        final remaining = expectedSize == null
            ? 0
            : max(expectedSize - partLength, 0);
        if (!quotaGate!(remaining)) {
          throw QuotaExceeded('下载配额不足，任务已挂起（$bookId）');
        }
      }

      if (!haveAll) {
        await _guard(() async {
          // 每次尝试（含 guard 内部重试）都重读 .part 长度：中断续传的依据。
          final currentLength = await part.exists() ? await part.length() : 0;
          final stream = _adapter.downloadBook(
            bookId,
            startByte: currentLength > 0 ? currentLength : null,
          );
          await part.parent.create(recursive: true);
          final sink = part.openWrite(
            mode: currentLength > 0 ? FileMode.append : FileMode.write,
          );
          try {
            await for (final chunk in stream) {
              sink.add(chunk);
              _countBytes(TransferDirection.download, chunk.length);
            }
            await sink.flush();
          } on Object {
            // 异常路径也要把已收字节落盘（.part 续传的前提），再上抛。
            await sink.flush();
            rethrow;
          } finally {
            await sink.close();
          }
        }, context: '下载正文 $bookId');
      }

      // 完整性校验（尺寸 + SHA-256）。
      final actualLength = await part.exists() ? await part.length() : 0;
      if (expectedSize != null && actualLength != expectedSize) {
        await _onVerifyFailure(
          part,
          '尺寸不符：期望 $expectedSize，实际 $actualLength',
          bookId: bookId,
          failures: ++verifyFailures,
        );
        continue;
      }
      if (expectedHash != null) {
        final actual = await _sha256HexOfFile(part);
        if (!_hashEquals(actual, expectedHash)) {
          await _onVerifyFailure(
            part,
            '哈希不符：期望 $expectedHash，实际 $actual',
            bookId: bookId,
            failures: ++verifyFailures,
          );
          continue;
        }
      }

      // 校验通过：rename 转正（Windows 上 rename 不覆盖，先清旧目标）。
      final target = File(targetPath);
      if (await target.exists()) await target.delete();
      await part.rename(targetPath);
      return;
    }
  }

  /// 校验失败统一处理：删除 `.part`（下次从头重下），重试耗尽抛 [Corruption]。
  Future<void> _onVerifyFailure(
    File part,
    String reason, {
    required String bookId,
    required int failures,
  }) async {
    if (await part.exists()) await part.delete();
    if (failures > retryPolicy.maxHashAttempts) {
      throw Corruption('正文校验失败且重试耗尽（$bookId）：$reason');
    }
  }

  /// 上传正文：包装 [BackendAdapter.uploadBook]，并发 1；
  /// 幂等（远端同 hash 跳过）与远端 hash 校验由适配器保证。
  ///
  /// [overwrite] 透传给适配器（FR-410 显式替换：跳过"远端已有不同版本"
  /// 检查直接覆盖；默认 false 保持 §5.3 语义）。
  Future<void> uploadFile(
    String bookId, {
    required String filePath,
    required String contentHash,
    bool overwrite = false,
  }) {
    return _uploadSlots.run(() async {
      final file = File(filePath);
      if (!await file.exists()) {
        throw Corruption('本地正文缺失，无法上传（$bookId）');
      }
      await _guard(
        () => _adapter.uploadBook(
          bookId,
          file,
          contentHash,
          overwrite: overwrite,
        ),
        context: '上传正文 $bookId',
      );
      _countBytes(TransferDirection.upload, await file.length());
    });
  }

  /// §8.4 重试执行器：网络/5xx/429 分类退避；401/[AuthFailed] 与
  /// [RevConflict] 不重试原样上抛；重试耗尽抛对应 [SyncError] 分类。
  Future<T> guard<T>(Future<T> Function() action, {String context = ''}) =>
      _guard(action, context: context);

  Future<T> _guard<T>(
    Future<T> Function() action, {
    required String context,
  }) async {
    var networkFailures = 0;
    var serverErrors = 0;
    var rateLimited = 0;
    while (true) {
      try {
        return await action();
      } on AuthFailed {
        rethrow; // 401：直接引导重新授权，不重试。
      } on RevConflict {
        rethrow; // 409/412/428：不进队列，由引擎走合并流程。
      } on BackendRequestException catch (e) {
        final code = e.statusCode;
        if (code == null) {
          // 网络超时/连接失败：指数退避，连续 5 次失败本轮放弃。
          networkFailures++;
          if (networkFailures >= retryPolicy.maxNetworkAttempts) {
            throw NetworkUnreachable('$context：网络连续失败，本轮放弃', e);
          }
          await _delay(_jittered(_backoffDelay(networkFailures)));
        } else if (code == 429 || code == 503) {
          // 限流：尊重 Retry-After；无头按 60s 固定等待。
          rateLimited++;
          if (rateLimited > retryPolicy.maxRateLimitAttempts) {
            throw ServerError('$context：限流重试次数用尽', e, code);
          }
          await _delay(e.retryAfter ?? retryPolicy.rateLimitFallback);
        } else if (code >= 500 && code < 600) {
          // 5xx：指数退避，最多 3 次重试。
          serverErrors++;
          if (serverErrors > retryPolicy.maxServerRetries) {
            throw ServerError('$context：服务端持续错误（HTTP $code）', e, code);
          }
          await _delay(_jittered(_backoffDelay(serverErrors)));
        } else if (code == 404) {
          // 云端资源缺失：不可重试，按 Corruption 处理（正文缺失/元数据悬空）。
          throw Corruption('$context：云端资源不存在（404）', e);
        } else {
          // 其他 4xx：不可重试，按服务端错误上抛。
          throw ServerError('$context：请求被拒绝（HTTP $code）', e, code);
        }
      }
    }
  }

  /// 第 failure 次（1-based）失败后的退避延迟：1s→2s→4s→…→上限 300s。
  Duration backoffDelay(int failure) => _backoffDelay(failure);

  /// 对 [delay] 施加 ±[RetryPolicy.jitterRatio] 抖动（可测：注入 Random）。
  Duration jitteredDelay(Duration delay) => _jittered(delay);

  Duration _backoffDelay(int failure) {
    final multiplier = pow(2, failure - 1).toInt();
    final raw = retryPolicy.baseDelay * multiplier;
    return raw > retryPolicy.maxDelay ? retryPolicy.maxDelay : raw;
  }

  Duration _jittered(Duration delay) {
    final ratio = retryPolicy.jitterRatio;
    final factor = 1.0 + ratio * (2 * _jitterRandom.nextDouble() - 1);
    final ms = (delay.inMilliseconds * factor).round();
    return Duration(milliseconds: max(ms, 0));
  }

  void _countBytes(TransferDirection dir, int bytes) {
    bytesByDirection[dir] = (bytesByDirection[dir] ?? 0) + bytes;
    onBytes?.call(dir, bytes);
    for (final listener in _bytesListeners) {
      listener(dir, bytes);
    }
  }

  static Future<String> _sha256HexOfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return 'sha256:${digest.toString()}';
  }

  static bool _hashEquals(String actual, String expected) {
    String norm(String v) =>
        v.startsWith('sha256:') ? v.substring('sha256:'.length) : v;
    return norm(actual).toLowerCase() == norm(expected).toLowerCase();
  }
}
