/// 同步状态可视化（FR-406）：全局状态 + 每书状态，drift/内存双源聚合。
///
/// - 全局：未配置 / 空闲 / 同步中 / 正常 / 失败（+原因分类文案）；
/// - 每书：synced / pendingUpload（dirty）/ placeholder（待下载）/
///   cloudMissing（云端缺失）/ error；
/// - drift 源：books.localPath（占位）与 progress.dirty（待上传），经书库
///   watcher 实时刷新；内存源：每轮同步报告的 cloudMissing 决策与逐书错误
///   （由 facade 写入 [syncMemoryStatusProvider]）。
/// UI 层（书库卡片/设置页）只消费 provider，不直接触碰引擎。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_core/sync_core.dart';

import '../../data/db/app_database.dart';
import '../library/library_providers.dart';

/// 全局同步状态 ID（配置未就绪时 facade 一切方法 no-op 并报告 unconfigured）。
enum SyncStateId { unconfigured, idle, syncing, ok, failed }

/// 每书同步状态。
enum BookSyncStatus {
  /// 与云端一致。
  synced,

  /// 有未推送的本地修改（progress.dirty）。
  pendingUpload,

  /// 占位书：云端有、本地无正文。
  placeholder,

  /// 云端缺失（曾有 baseRev 而远端 meta 消失，docs/04 §5.1 第 7b 行）。
  cloudMissing,

  /// 上一轮同步该书记录了错误。
  error,
}

/// [SyncError] 六类 → 中文分类文案（FR-406：网络不可达/密码错误/
/// 坚果云流量超额/冲突无法自动解决/服务异常/文件损坏）。
String syncErrorText(SyncError error) => switch (error) {
  NetworkUnreachable() => '网络不可达，请检查网络连接',
  AuthFailedSyncError() => '密码错误或账号失效，请重新配置',
  QuotaExceeded() => '坚果云流量超额，同步已暂停',
  ConflictUnresolvable() => '冲突无法自动解决',
  ServerError() => '服务异常，请稍后重试',
  Corruption() => '文件损坏，该书已跳过同步',
};

/// facade 每轮同步后上报的结果（provider 装配层转成内存侧状态）。
class SyncStatusOutcome {
  const SyncStatusOutcome({
    required this.stateId,
    this.lastSyncedAt,
    this.failureText,
    this.quotaWarnText,
    this.report,
  });

  final SyncStateId stateId;
  final DateTime? lastSyncedAt;

  /// 失败原因（分类文案，FR-406）。
  final String? failureText;

  /// 配额告警文案（docs/04 §8.3 的 80% 常驻提醒）。
  final String? quotaWarnText;

  /// 本轮同步报告（逐书决策/错误来源）。
  final SyncReport? report;
}

/// 内存侧状态（facade 写入；书级 dirty/placeholder 由 drift watcher 实时源）。
class SyncMemoryStatus {
  const SyncMemoryStatus({
    this.id = SyncStateId.unconfigured,
    this.lastSyncedAt,
    this.failureText,
    this.quotaWarnText,
    this.cloudMissing = const <String>{},
    this.bookErrors = const <String, String>{},
  });

  final SyncStateId id;
  final DateTime? lastSyncedAt;
  final String? failureText;
  final String? quotaWarnText;

  /// 本轮被判定"云端缺失"的书。
  final Set<String> cloudMissing;

  /// bookId → 分类错误文案。
  final Map<String, String> bookErrors;
}

/// 内存侧状态 provider（facade 经 [SyncStatusOutcome] 更新）。
final syncMemoryStatusProvider =
    NotifierProvider<SyncMemoryStatusNotifier, SyncMemoryStatus>(
      SyncMemoryStatusNotifier.new,
    );

final class SyncMemoryStatusNotifier extends Notifier<SyncMemoryStatus> {
  @override
  SyncMemoryStatus build() => const SyncMemoryStatus();

  /// 标记同步中（保留上次同步时间与告警）。
  void markSyncing() {
    state = SyncMemoryStatus(
      id: SyncStateId.syncing,
      lastSyncedAt: state.lastSyncedAt,
      quotaWarnText: state.quotaWarnText,
    );
  }

  /// 应用一轮同步结果：拆出 cloudMissing 集合与逐书错误文案。
  void applyOutcome(SyncStatusOutcome outcome) {
    final cloudMissing = <String>{};
    final bookErrors = <String, String>{};
    final report = outcome.report;
    if (report != null) {
      for (final result in report.results) {
        if (result.decision == SyncDecision.cloudMissing) {
          cloudMissing.add(result.bookId);
        }
        if (!result.ok && result.error != null) {
          bookErrors[result.bookId] = syncErrorText(result.error!);
        }
      }
    }
    state = SyncMemoryStatus(
      id: outcome.stateId,
      lastSyncedAt: outcome.lastSyncedAt ?? state.lastSyncedAt,
      failureText: outcome.failureText,
      quotaWarnText: outcome.quotaWarnText ?? state.quotaWarnText,
      cloudMissing: cloudMissing,
      bookErrors: bookErrors,
    );
  }

  /// 回到未配置（清除凭据后）。
  void markUnconfigured() {
    state = const SyncMemoryStatus(id: SyncStateId.unconfigured);
  }

  /// 更新配额告警文案（null = 解除）。
  void setQuotaWarn(String? text) {
    state = SyncMemoryStatus(
      id: state.id,
      lastSyncedAt: state.lastSyncedAt,
      failureText: state.failureText,
      quotaWarnText: text,
      cloudMissing: state.cloudMissing,
      bookErrors: state.bookErrors,
    );
  }
}

/// 每书状态聚合：drift（localPath/dirty）× 内存（cloudMissing/错误）双源。
final bookSyncStatusMapProvider = Provider<Map<String, BookSyncStatus>>((ref) {
  final books = ref.watch(booksStreamProvider).value;
  final progressMap = ref.watch(progressMapProvider).value;
  final memory = ref.watch(syncMemoryStatusProvider);
  final result = <String, BookSyncStatus>{};
  for (final book in books ?? const <Book>[]) {
    result[book.bookId] = _resolveBookStatus(
      book,
      progressMap?[book.bookId],
      memory,
    );
  }
  return result;
});

/// 单书状态判定（优先级：error > placeholder > cloudMissing > pendingUpload > synced）。
BookSyncStatus _resolveBookStatus(
  Book book,
  BookProgress? progress,
  SyncMemoryStatus memory,
) {
  if (memory.bookErrors.containsKey(book.bookId)) {
    return BookSyncStatus.error;
  }
  if ((book.localPath ?? '').isEmpty) {
    return BookSyncStatus.placeholder;
  }
  if (memory.cloudMissing.contains(book.bookId)) {
    return BookSyncStatus.cloudMissing;
  }
  if (progress?.dirty ?? false) {
    return BookSyncStatus.pendingUpload;
  }
  return BookSyncStatus.synced;
}

/// 每书状态的中文短标签（书卡角标用）。
String? bookSyncStatusLabel(BookSyncStatus? status) => switch (status) {
  BookSyncStatus.pendingUpload => '待上传',
  BookSyncStatus.placeholder => '云端',
  BookSyncStatus.cloudMissing => '云端缺失',
  BookSyncStatus.error => '失败',
  _ => null,
};
