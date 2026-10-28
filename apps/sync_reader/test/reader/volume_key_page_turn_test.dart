/// VolumeKeyPageTurn 服务测试（FR-209）：注入通道 + TestDefaultBinaryMessenger
/// 拦截（手法参考平台通道 mock 约定：setMockMethodCallHandler /
/// setMockStreamHandler），验证 enableVolumeKeys 方法参数契约、'up'/'down'
/// 事件转发与非 Android 平台 no-op（平台判定注入，覆盖 Android 分支）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/reader/volume_key_page_turn.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('sync_reader/platform_reader');
  const eventChannel = EventChannel('sync_reader/platform_reader/volume_keys');

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test('Android：enable 下发 enabled 参数，up/down 事件转发到 events 流', () async {
    final calls = <Map<String, Object?>>[];
    MockStreamHandlerEventSink? nativeSink;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      calls.add(Map<String, Object?>.from(call.arguments as Map));
      return null;
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => nativeSink = events,
      ),
    );

    final service = VolumeKeyPageTurn(
      methodChannel: method,
      eventChannel: eventChannel,
      isAndroid: () => true,
    );
    addTearDown(service.dispose);

    final received = <String>[];
    final sub = service.events.listen(received.add);

    await service.setEnabled(true);
    expect(calls, [
      {'enabled': true},
    ], reason: '启用时向原生下发 enabled=true');

    // 语义冻结：'up' = 音量上键（上一页）/ 'down' = 音量下键（下一页），
    // 服务只转发字符串，翻页映射由阅读页完成。
    nativeSink?.success('up');
    nativeSink?.success('down');
    await Future<void>.delayed(Duration.zero);
    expect(received, ['up', 'down']);

    await service.setEnabled(false);
    expect(calls.last, {'enabled': false}, reason: '停用时下发 enabled=false');
    await sub.cancel();
  });

  test('非 Android：setEnabled 为 no-op，不触达任何通道', () async {
    var methodCalled = false;
    var listened = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(method, (call) async {
      methodCalled = true;
      return null;
    });
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => listened = true,
      ),
    );

    final service = VolumeKeyPageTurn(isAndroid: () => false);
    addTearDown(service.dispose);
    final received = <String>[];
    final sub = service.events.listen(received.add);

    await service.setEnabled(true);

    expect(methodCalled, isFalse, reason: '非 Android 不得调用 MethodChannel');
    expect(listened, isFalse, reason: '非 Android 不得订阅 EventChannel');
    expect(received, isEmpty);
    await sub.cancel();
  });
}
