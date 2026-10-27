/// 占位书正文按需下载的 UI 接线（FR-402，docs/04 §3 触发时机第 7 行 /
/// docs/04 §5.4）。
///
/// 三个入口（书库占位卡片点开 / 详情页"下载正文"按钮 / 阅读页占位态）
/// 全部汇聚到 [downloadPlaceholderBook]：
/// - 未配置同步账号 → 提示配置，不做任何同步动作（FR-405 no-op 语义）；
/// - 下载期间显示常驻 snackbar（indeterminate 进度；TransferQueue 不提供
///   单书百分比回调，KB 级正文整段到达即可）；
/// - 失败（Wi-Fi 限制/配额/网络）→ 提示可重试；本地 `localPath` 保持为空，
///   占位形态不丢（卡片仍带"仅云端"角标），再次点开即重试；
/// - 成功 → 失效一次性详情 provider（books 列表/进度徽标走 drift watch
///   自动刷新）并返回 true，由调用方决定"正常打开"（进阅读页）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/library_providers.dart' show bookDetailProvider;
import 'sync_facade.dart';

/// 下载占位书正文（带 UI 反馈）。返回是否下载成功。
Future<bool> downloadPlaceholderBook(
  BuildContext context,
  WidgetRef ref, {
  required String bookId,
  required String title,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final facade = ref.read(syncFacadeProvider);
  try {
    if (await facade.readConfig() == null) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('尚未配置同步账号，请先在"同步设置"中完成配置'),
          duration: Duration(seconds: 5),
        ),
      );
      return false;
    }
  } catch (_) {
    // 安全存储不可用（如无平台通道的测试环境）：按未配置处理。
    messenger.showSnackBar(
      const SnackBar(
        content: Text('尚未配置同步账号，请先在"同步设置"中完成配置'),
        duration: Duration(seconds: 5),
      ),
    );
    return false;
  }

  final progress = messenger.showSnackBar(
    SnackBar(
      duration: const Duration(minutes: 10),
      content: Text('正在下载《$title》…'),
    ),
  );
  final ok = await facade.downloadPlaceholder(bookId);
  progress.close();
  if (ok) {
    // 书库刷新：占位 → 可读（详情/TOC 为一次性源需失效；列表走 drift watch）。
    ref.invalidate(bookDetailProvider);
    return true;
  }
  messenger.showSnackBar(
    const SnackBar(
      content: Text('下载未完成，可稍后重试（失败不影响云端书目）'),
      duration: Duration(seconds: 5),
    ),
  );
  return false;
}
