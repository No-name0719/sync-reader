/// 连接测试结果展示（同步设置页后端卡与坚果云向导页共用）。
///
/// 设计语言与设置页一致：卡片 = `t.surface` + `AppRadius.lg` + 1px `t.border`；
/// 成功用 success 令牌、失败用 danger 令牌。
///
/// 展示规格：
/// - 成功：一行成功色「连接正常 · 列目录 274 ms」+ 能力摘要
///   （MOVE / ETag / Range 支持情况）；
/// - 失败：危险色一行「连接失败」+ 失败分类文案 + 步骤明细
///   （哪一步失败 / 状态码 / 延迟）。
///
/// 硬约束：步骤明细只含步骤名、HTTP 状态码与延迟，绝不含账号/密码（NFR-03）。
library;

import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import 'connection_test.dart';

/// 连接测试结果卡（成功 / 失败两态）。
class ConnectionTestResultView extends StatelessWidget {
  const ConnectionTestResultView({super.key, required this.result});

  /// 测试结果。
  final ConnectionTestResult result;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _summary(context),
          if (result.success) ...[
            const SizedBox(height: AppSpacing.s2),
            _capabilities(context),
          ] else ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              result.failureText ?? '连接失败',
              style: t.sm.copyWith(color: t.danger),
            ),
            const SizedBox(height: AppSpacing.s3),
            _stepDetails(context),
          ],
        ],
      ),
    );
  }

  /// 标题行：成功「连接正常 · 列目录 N ms」/ 失败「连接失败」。
  Widget _summary(BuildContext context) {
    final t = context.appTokens;
    final latency = _listLatencyMs;
    final text = result.success
        ? (latency == null ? '连接正常' : '连接正常 · 列目录 $latency ms')
        : '连接失败';
    return Row(
      children: [
        Icon(
          result.success ? Icons.check_circle : Icons.error_outline,
          size: 16,
          color: result.success ? t.success : t.danger,
        ),
        const SizedBox(width: AppSpacing.s2),
        Expanded(
          child: Text(
            text,
            style: t.sm.copyWith(
              color: result.success ? t.success : t.danger,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// 能力摘要（MOVE / ETag / Range 支持情况）。
  Widget _capabilities(BuildContext context) {
    final t = context.appTokens;
    final caps = result.capabilities;
    if (caps == null) return const SizedBox.shrink();
    return Text(
      'MOVE ${caps.supportsMove ? '支持' : '不支持'} · '
      'ETag ${caps.supportsEtag ? '支持' : '不支持'} · '
      'Range ${caps.supportsRange ? '支持' : '不支持'}',
      style: t.caption.copyWith(color: t.text3),
    );
  }

  /// 步骤明细（失败时展示）：步骤名 + 延迟 + 状态码附注。
  Widget _stepDetails(BuildContext context) {
    final t = context.appTokens;
    if (result.steps.isEmpty) {
      return Text('未取得步骤明细', style: t.caption.copyWith(color: t.text3));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final step in result.steps)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  step.ok ? Icons.check_circle : Icons.cancel,
                  size: 14,
                  color: step.ok ? t.text3 : t.danger,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    step.name,
                    style: t.caption.copyWith(
                      color: step.ok ? t.text2 : t.danger,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (step.detail != null) ...[
                  const SizedBox(width: AppSpacing.s2),
                  Text(
                    step.detail!,
                    style: t.caption.copyWith(
                      color: step.ok ? t.text3 : t.danger,
                    ),
                  ),
                ],
                const SizedBox(width: AppSpacing.s2),
                Text(
                  step.latencyMs == null ? '-' : '${step.latencyMs} ms',
                  style: t.caption.copyWith(color: t.text3),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 「列目录」步骤的往返延迟（ms）；无该步骤时退回第一步。
  int? get _listLatencyMs {
    for (final step in result.steps) {
      if (step.name == '列目录') return step.latencyMs;
    }
    return result.steps.isEmpty ? null : result.steps.first.latencyMs;
  }
}
