/// 首次启动引导页（`/onboarding`）：坚果云同步的初始化入口，**可跳过**。
///
/// 版式（docs/10 §4.9，已确认稿）：
/// 品牌标 → 坚果云卡（图标 + 三条好处）→ 「配置坚果云同步」/「暂不配置，先用本地」。
///
/// 行为：
/// - 「配置坚果云同步」→ 进入四步向导（首启专用路由 `/onboarding/guide`，
///   不套应用外壳，保持全屏）；向导保存成功后回本页并完成首启；
/// - 「暂不配置，先用本地」→ 落首启标志，直接进书库（同步保持未配置，
///   沿用外壳角标 / 同步页 / 书库横幅三处既有提示，不做二次打扰）。
///
/// 判定与标志读写见 `app/onboarding.dart`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/onboarding.dart';
import '../../app/providers.dart';
import '../../core/design_tokens.dart';
import '../../shared/icon_alignment.dart';

/// 首启引导页。
class OnboardingPage extends ConsumerWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    return Scaffold(
      backgroundColor: t.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s5,
              vertical: AppSpacing.s6,
            ),
            // 内容比视口矮 → 垂直居中；比视口高 → 可滚动（不截断）。
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - AppSpacing.s6 * 2,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _BrandMark(),
                      const SizedBox(height: AppSpacing.s6),
                      const _NutstoreCard(),
                      const SizedBox(height: AppSpacing.s4),
                      FilledButton(
                        onPressed: () => _configure(context, ref),
                        style: FilledButton.styleFrom(
                          backgroundColor: t.brand,
                          foregroundColor: Colors.white,
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          textStyle: t.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('配置坚果云同步'),
                            SizedBox(width: AppSpacing.s1),
                            Icon(Icons.arrow_forward, size: 16),
                          ],
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s2),
                      OutlinedButton(
                        onPressed: () => _skip(context, ref),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: t.text2,
                          side: BorderSide(color: t.borderStrong),
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          textStyle: t.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        child: const Text('暂不配置，先用本地'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 进四步向导：保存成功（向导 pop(true)）才算首启完成，中途返回则留在本页。
  Future<void> _configure(BuildContext context, WidgetRef ref) async {
    final saved = await context.push<bool>('/onboarding/guide');
    if (saved != true || !context.mounted) return;
    await _finish(context, ref);
  }

  /// 跳过：落首启标志后直接进书库。
  Future<void> _skip(BuildContext context, WidgetRef ref) async {
    await _finish(context, ref);
  }

  /// 首启完成：落标志 → 进书库。
  ///
  /// 先落库再跳转：跳转时路由 redirect 会读闸门状态，状态必须已是终态，
  /// 否则会被 redirect 弹回首启页。
  Future<void> _finish(BuildContext context, WidgetRef ref) async {
    await onboardingGate.markCompleted(ref.read(appSettingsDaoProvider));
    if (context.mounted) context.go('/');
  }
}

/// 品牌标：赭石圆角方块 + 白色打开的书（与应用图标、外壳品牌区一致）。
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final titleStyle = t.sm.copyWith(fontSize: 14, fontWeight: FontWeight.w600);
    return Row(
      children: [
        // 品牌方块（30）比标题行盒（14×20/13 ≈ 21.5）高 → 块心下移半格，
        // 看着「图标和字没对齐」。IconLineSlot 把块心提到标题行盒中心。
        IconLineSlot(
          lineHeight: textLineHeight(titleStyle),
          childSize: 30,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: t.brand,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: const Icon(
              Icons.auto_stories,
              size: 17,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s2),
        Text('SyncReader', style: titleStyle),
        const SizedBox(width: AppSpacing.s2),
        Text('阅读进度同步', style: t.tertiary),
      ],
    );
  }
}

/// 坚果云卡：图标 + 三条好处（与同步设置页的「坚」图标块同款）。
class _NutstoreCard extends StatelessWidget {
  const _NutstoreCard();

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
        boxShadow: t.sh2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        t.info,
                        Color.alphaBlend(Colors.black26, t.info),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Text(
                    '坚',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('坚果云同步', style: t.h3),
                      Text('免费', style: t.tertiary),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: t.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s4,
              AppSpacing.s2,
              AppSpacing.s4,
              AppSpacing.s3,
            ),
            child: const Column(
              children: [
                _BenefitRow(
                  icon: Icons.smartphone_outlined,
                  title: '多端续读',
                  desc: '换一台设备接着读，进度自动对齐',
                ),
                _BenefitRow(
                  icon: Icons.cloud_upload_outlined,
                  title: '书库共享',
                  desc: '同一本书在所有设备上都能看到',
                ),
                _BenefitRow(
                  icon: Icons.all_inclusive,
                  title: '不占本地',
                  desc: '正文按需下载，不塞满手机存储',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条好处：软底图标块 + 标题 + 说明。
class _BenefitRow extends StatelessWidget {
  const _BenefitRow({
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 徽标块（26）比标题行盒（body 14×22 = 22）高 → 块心偏低；
          // IconLineSlot 把块心提到标题首行中心。
          IconLineSlot(
            lineHeight: textLineHeight(
              t.body.copyWith(fontWeight: FontWeight.w600),
            ),
            childSize: 26,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: t.brandSoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(icon, size: 15, color: t.brandText),
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: t.body.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(desc, style: t.sm.copyWith(color: t.text2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
