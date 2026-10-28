/// 音量键翻页服务（FR-209，Android 专属）：经平台通道启用/停用原生
/// 音量键拦截，并接收原生转发来的按键事件。
///
/// 通道约定（与 MainActivity.kt 对应）：
/// - MethodChannel `sync_reader/platform_reader`，方法
///   `enableVolumeKeys`（参数 `enabled: Boolean`）；
/// - EventChannel `sync_reader/platform_reader/volume_keys`，事件字符串
///   `'up'`（音量上键）/ `'down'`（音量下键）。
///
/// 重建约定：Activity 重建（旋转等）后原生拦截状态重置为 false，由 Dart
/// 侧在阅读会话就绪后重新 `setEnabled(true)` 主动恢复（阅读页负责接线）。
///
/// 语义冻结：音量上键 = 上一页，音量下键 = 下一页（映射在阅读页完成，
/// 本服务只转发事件字符串）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// MethodChannel 名（与 MainActivity.kt 约定，勿改）。
const MethodChannel _defaultMethodChannel = MethodChannel(
  'sync_reader/platform_reader',
);

/// EventChannel 名（与 MainActivity.kt 约定，勿改）。
const EventChannel _defaultEventChannel = EventChannel(
  'sync_reader/platform_reader/volume_keys',
);

/// 音量键翻页服务。
///
/// [methodChannel]/[eventChannel]/[isAndroid] 可注入（测试用
/// TestDefaultBinaryMessengerBinding 拦截通道、注入平台判定）；默认连到
/// 原生约定通道并以 [Platform.isAndroid] 判定平台。
class VolumeKeyPageTurn {
  VolumeKeyPageTurn({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    bool Function()? isAndroid,
  }) : _methodChannel = methodChannel ?? _defaultMethodChannel,
       _eventChannel = eventChannel ?? _defaultEventChannel,
       _isAndroid = isAndroid ?? _defaultPlatformCheck;

  /// 生产平台判定（可注入替换，测试宿主非 Android）。
  static bool _defaultPlatformCheck() => Platform.isAndroid;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;
  final bool Function() _isAndroid;

  StreamSubscription<Object?>? _nativeSub;
  final StreamController<String> _events = StreamController<String>.broadcast();
  bool _disposed = false;

  /// 音量键事件流：`'up'` = 音量上键（上一页）/ `'down'` = 音量下键（下一页）。
  Stream<String> get events => _events.stream;

  /// 启用/停用音量键拦截。
  ///
  /// 仅 Android 生效（原生拦截依赖 KEYCODE 分发）；其他平台 no-op。
  /// enabled=true 时先订阅原生事件流再调用方法（避免启用后事件无监听）；
  /// enabled=false 时取消订阅并通知原生恢复系统音量键默认行为。
  Future<void> setEnabled(bool enabled) async {
    if (_disposed || !_isAndroid()) return;
    if (enabled) {
      _nativeSub ??= _eventChannel.receiveBroadcastStream().listen(
        (event) {
          if (event is String) _events.add(event); // 非字符串事件安全忽略
        },
        onError: _events.addError,
        cancelOnError: false,
      );
    } else {
      await _nativeSub?.cancel();
      _nativeSub = null;
    }
    await _methodChannel.invokeMethod<void>('enableVolumeKeys', {
      'enabled': enabled,
    });
  }

  /// 释放资源（取消原生订阅、关闭事件流；阅读页 dispose 时调用）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _nativeSub?.cancel();
    _nativeSub = null;
    await _events.close();
  }
}
