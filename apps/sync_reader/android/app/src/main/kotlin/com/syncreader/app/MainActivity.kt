package com.syncreader.app

import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 音量键翻页（FR-209，Android 专属）平台通道：
 * - MethodChannel `sync_reader/platform_reader`：方法 `enableVolumeKeys`
 *   （参数 enabled: Boolean），控制是否拦截音量键；
 * - EventChannel `sync_reader/platform_reader/volume_keys`：向 Dart 转发
 *   按键事件字符串 "up"（音量上键）/ "down"（音量下键）。
 *
 * 语义冻结：音量上键 = 上一页，音量下键 = 下一页（映射由 Dart 侧完成，
 * 原生只上报方向字符串）。
 *
 * 状态约定：enabled 默认 false；FlutterEngine 重建（Activity 重建、旋转等）
 * 后通道重新挂载时状态一律回到 false，由 Dart 侧在阅读会话就绪后主动
 * `enableVolumeKeys(true)` 一次恢复——Dart 不持久化该开关的通道状态，
 * 以本重发约定为准。
 */
class MainActivity : FlutterActivity() {

    /// 是否拦截音量键（Dart 经 MethodChannel 设置；默认 false = 系统默认行为）。
    private var volumeKeysEnabled = false

    /// 音量键事件接收器（Dart 侧未监听时为 null，发送前安全判空）。
    private var volumeKeySink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 通道重挂（引擎重建）即重置拦截状态，等待 Dart 侧重发 enable（见类注释约定）。
        volumeKeysEnabled = false
        volumeKeySink = null
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enableVolumeKeys" -> {
                    volumeKeysEnabled = call.argument<Boolean>("enabled") ?: false
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeKeySink = events
                }

                override fun onCancel(arguments: Any?) {
                    volumeKeySink = null
                }
            },
        )
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // 引擎拆卸：停拦截、弃 sink（通道已不可用，保持状态一致）。
        volumeKeysEnabled = false
        volumeKeySink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (volumeKeysEnabled && event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                // 仅拦截 ACTION_DOWN（长按连发即连翻）；返回 true 消费事件，
                // 不再交由系统调节音量。sink 为空（Dart 未监听）时安全忽略。
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeKeySink?.success(EVENT_VOLUME_UP)
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeKeySink?.success(EVENT_VOLUME_DOWN)
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private companion object {
        const val METHOD_CHANNEL = "sync_reader/platform_reader"
        const val EVENT_CHANNEL = "sync_reader/platform_reader/volume_keys"
        const val EVENT_VOLUME_UP = "up"
        const val EVENT_VOLUME_DOWN = "down"
    }
}
