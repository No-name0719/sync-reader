/// 统一错误分类（docs/03 §6.1 SyncError 六类）——M2 已收敛到 sync_core 的
/// 权威定义（认证类名为 `AuthFailedSyncError`），本文件只保留：
/// - 六类异常与映射器的 re-export（全仓统一从此导入）；
/// - UI 分类文案 [SyncErrorUserMessage.userMessage]（FR-406：UI 只见文案，
///   不暴露堆栈；六类分别对应 网络不可达/密码错误/流量超额/冲突/服务异常/
///   文件损坏）。
library;

import 'package:sync_core/sync_core.dart';

export 'package:sync_core/sync_core.dart'
    show
        ConflictUnresolvable,
        Corruption,
        NetworkUnreachable,
        QuotaExceeded,
        ServerError,
        SyncError,
        SyncErrorMapper,
        AuthFailedSyncError;

/// UI 面向用户的分类文案扩展（FR-406）。
extension SyncErrorUserMessage on SyncError {
  /// 分类文案（中文，穷举六类；穷举式 switch 保证新增分类时编译期补齐）。
  String get userMessage => switch (this) {
    NetworkUnreachable() => '网络不可用，请检查网络连接后重试',
    AuthFailedSyncError() => '登录凭据无效或已过期，请重新配置账号',
    QuotaExceeded() => '同步流量已达本月上限，同步已暂停',
    ConflictUnresolvable() => '同步冲突无法自动解决，请手动选择保留版本',
    ServerError() => '服务器出错，请稍后重试',
    Corruption() => '数据损坏，该书已跳过同步，可尝试删除后重新导入',
  };
}
