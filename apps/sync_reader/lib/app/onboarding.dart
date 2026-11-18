/// 首启闸门（首次启动引导页的状态判定；docs/10 §4.9）。
///
/// 判定依据是 `app_settings` 表里的 `app.onboarding.done` 标志：
/// - 标志不存在 → 首启未完成 → 展示首启页（坚果云配置入口，**可跳过**）；
/// - 标志存在 → 首启已完成 → 直接进书库，之后不再打扰。
///
/// 标志在**首帧之前**读回（见 main.dart），因此首启页与书库之间不会闪一帧：
/// 路由 redirect 第一次求值时状态已是终态，无需「先显示书库再跳走」。
///
/// 失败策略一律**放开**：读表失败按「已完成」处理（宁可少弹一次首启页，
/// 也绝不把用户挡在启动之外）；落库失败则内存态照常切到「已完成」
/// （下次启动会再问一次，用户可再跳过）。
///
/// 本类是**全局单例**（与全局 router 同风格）：路由 redirect 与首启页
/// 需要共用同一份状态，故不走 Riverpod 注入。
library;

import 'package:flutter/foundation.dart';

import '../data/db/daos/app_settings_dao.dart';

/// `app_settings` 表里的首启标志键名。
abstract final class OnboardingKeys {
  /// 首启已完成（值为 `'1'`）。
  static const String done = 'app.onboarding.done';

  /// 标志的“已完成”取值。
  static const String doneValue = '1';
}

/// 首启状态。
enum OnboardingStatus {
  /// 尚未判定（读标志之前；测试环境默认）。
  unknown,

  /// 需要展示首启页。
  pending,

  /// 首启已完成（用户跳过或配置完成），不再打扰。
  completed,
}

/// 首启闸门：状态持有者 + 标志读写。
class OnboardingGate extends ChangeNotifier {
  OnboardingStatus _status = OnboardingStatus.unknown;

  /// 当前状态。
  OnboardingStatus get status => _status;

  /// 是否需要展示首启页。
  bool get needsOnboarding => _status == OnboardingStatus.pending;

  /// 读回持久化标志，决定首屏。
  ///
  /// 读表失败（数据库不可用等）按「已完成」处理：不阻断启动、不弹首启页。
  Future<void> load(AppSettingsDao dao) async {
    try {
      final raw = await dao.getValue(OnboardingKeys.done);
      _set(
        raw == OnboardingKeys.doneValue
            ? OnboardingStatus.completed
            : OnboardingStatus.pending,
      );
    } catch (_) {
      _set(OnboardingStatus.completed);
    }
  }

  /// 标记首启完成（用户跳过，或在向导里配好了坚果云）：落库 + 切状态。
  Future<void> markCompleted(AppSettingsDao dao) async {
    try {
      await dao.setValue(OnboardingKeys.done, OnboardingKeys.doneValue);
    } catch (_) {
      // 落库失败静默：内存态照常切换，不把用户卡在首启页。
    }
    _set(OnboardingStatus.completed);
  }

  /// 直接置状态（测试用；生产路径只经 [load] / [markCompleted]）。
  void reset(OnboardingStatus status) => _set(status);

  void _set(OnboardingStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }
}

/// 全局闸门实例：路由 redirect 与首启页共用这一份状态。
final OnboardingGate onboardingGate = OnboardingGate();
