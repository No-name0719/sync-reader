/// 同步触发器测试（docs/04 §3 六种触发时机）：
/// fake 时钟驱动的启动延迟/防抖/定时器、离台 >5min 恢复、网络恢复、
/// autoSyncEnabled=false 时仅手动生效。
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';
import 'package:sync_reader/features/sync/sync_preferences.dart';
import 'package:sync_reader/features/sync/sync_triggers.dart';

void main() {
  // attach() 需要 WidgetsBinding（生命周期观察注册）；单测环境显式初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<SyncTriggerSource> syncCalls;
  late List<String> pushCalls;
  late SyncPreferences prefs;
  late DateTime clock;
  late StreamController<List<ConnectivityResult>> connectivity;
  late SyncTriggers triggers;

  setUp(() {
    syncCalls = [];
    pushCalls = [];
    prefs = const SyncPreferences();
    clock = DateTime(2026, 10, 27, 9);
    connectivity = StreamController<List<ConnectivityResult>>.broadcast();
  });

  tearDown(() async => connectivity.close());

  SyncTriggers build() => SyncTriggers(
    runSync: (source) async {
      syncCalls.add(source);
      return null;
    },
    pushBookMeta: (bookId) async {
      pushCalls.add(bookId);
    },
    preferences: () => prefs,
    connectivityStream: connectivity.stream,
    now: () => clock,
  );

  group('自动同步总闸（autoSyncEnabled=false 时仅手动生效）', () {
    test('关闭时：启动/定时/网络恢复均不触发', () {
      fakeAsync((async) {
        prefs = const SyncPreferences(autoSyncEnabled: false);
        triggers = build()..attach();
        // 启动延迟到期。
        async.elapse(const Duration(seconds: 3));
        // 网络恢复。
        connectivity.add(const [ConnectivityResult.wifi]);
        async.flushMicrotasks();
        // 定时器到期。
        async.elapse(const Duration(minutes: 16));
        expect(syncCalls, isEmpty);
        triggers.detach();
      });
    });

    test('关闭时：进度防抖不推送；手动仍可用', () {
      fakeAsync((async) {
        prefs = const SyncPreferences(autoSyncEnabled: false);
        triggers = build()..attach();
        triggers.onProgressChanged('b1');
        async.elapse(const Duration(seconds: 11));
        expect(pushCalls, isEmpty);
        unawaited(triggers.flushProgress('b1'));
        async.flushMicrotasks();
        expect(pushCalls, isEmpty);
        unawaited(triggers.manualSync());
        async.flushMicrotasks();
        expect(syncCalls, [SyncTriggerSource.manual]);
        triggers.detach();
      });
    });
  });

  group('触发时机 1/5：启动延迟与前台定时', () {
    test('启动后 2s 全量一次；15min 定时逐次全量', () {
      fakeAsync((async) {
        triggers = build()..attach();
        async.elapse(const Duration(seconds: 1, milliseconds: 999));
        expect(syncCalls, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(syncCalls, [SyncTriggerSource.appStart]);
        async.elapse(const Duration(minutes: 15));
        expect(syncCalls, [
          SyncTriggerSource.appStart,
          SyncTriggerSource.periodic,
        ]);
        async.elapse(const Duration(minutes: 15));
        expect(syncCalls, hasLength(3));
        triggers.detach();
        async.flushTimers();
      });
    });

    test('attach 前 2s 内 detach：不再触发', () {
      fakeAsync((async) {
        triggers = build()..attach();
        triggers.detach();
        async.elapse(const Duration(minutes: 30));
        expect(syncCalls, isEmpty);
      });
    });
  });

  group('触发时机 2：离台 >5min 回前台', () {
    test('离台 4min 回前台不触发；6min 触发一次', () {
      triggers = build();
      // 切后台。
      triggers.didChangeAppLifecycleState(AppLifecycleState.paused);
      clock = clock.add(const Duration(minutes: 4));
      triggers.handleResume(clock);
      expect(syncCalls, isEmpty);
      // 再次切后台 >5min。
      triggers.didChangeAppLifecycleState(AppLifecycleState.hidden);
      clock = clock.add(const Duration(minutes: 6));
      triggers.handleResume(clock);
      expect(syncCalls, [SyncTriggerSource.lifecycleResume]);
      // 连续 resume（无离台记录）不触发。
      triggers.handleResume(clock);
      expect(syncCalls, hasLength(1));
    });

    test('桌面 hidden 与移动 paused 都算离台', () {
      triggers = build();
      triggers.didChangeAppLifecycleState(AppLifecycleState.inactive);
      clock = clock.add(const Duration(minutes: 6));
      triggers.handleResume(clock);
      expect(syncCalls, [SyncTriggerSource.lifecycleResume]);
    });
  });

  group('触发时机 3：进度防抖 10s / flush 立即', () {
    test('10s 窗口内重复变更合并为尾随一次推送', () {
      fakeAsync((async) {
        triggers = build()..attach();
        triggers.onProgressChanged('b1');
        async.elapse(const Duration(seconds: 5));
        triggers.onProgressChanged('b1');
        async.elapse(const Duration(seconds: 5));
        expect(pushCalls, isEmpty); // 第二次重置窗口。
        async.elapse(const Duration(seconds: 5));
        expect(pushCalls, ['b1']);
        triggers.detach();
        async.flushTimers();
      });
    });

    test('不同书独立防抖', () {
      fakeAsync((async) {
        triggers = build()..attach();
        triggers.onProgressChanged('b1');
        triggers.onProgressChanged('b2');
        async.elapse(const Duration(seconds: 10));
        expect(pushCalls.toSet(), {'b1', 'b2'});
        triggers.detach();
        async.flushTimers();
      });
    });

    test('flushProgress 取消挂起防抖并立即推送', () {
      fakeAsync((async) {
        triggers = build()..attach();
        triggers.onProgressChanged('b1');
        async.elapse(const Duration(seconds: 3));
        unawaited(triggers.flushProgress('b1'));
        async.flushMicrotasks();
        expect(pushCalls, ['b1']);
        async.elapse(const Duration(seconds: 10));
        expect(pushCalls, ['b1']); // 防抖已被取消，不重复推送。
        triggers.detach();
      });
    });

    test('cancelProgressDebounce 仅取消不推送', () {
      fakeAsync((async) {
        triggers = build()..attach();
        triggers.onProgressChanged('b1');
        triggers.cancelProgressDebounce('b1');
        async.elapse(const Duration(seconds: 11));
        expect(pushCalls, isEmpty);
        triggers.detach();
      });
    });
  });

  group('触发时机 4：网络恢复', () {
    test('none → wifi 触发一次；持续有网不重复触发', () {
      fakeAsync((async) {
        triggers = build()..attach();
        connectivity.add(const [ConnectivityResult.none]);
        async.flushMicrotasks();
        connectivity.add(const [ConnectivityResult.wifi]);
        async.flushMicrotasks();
        expect(syncCalls, [SyncTriggerSource.networkRestored]);
        connectivity.add(const [ConnectivityResult.ethernet]);
        async.flushMicrotasks();
        expect(syncCalls, hasLength(1));
        connectivity.add(const [ConnectivityResult.none]);
        async.flushMicrotasks();
        connectivity.add(const [ConnectivityResult.mobile]);
        async.flushMicrotasks();
        expect(syncCalls, hasLength(2));
        triggers.detach();
      });
    });

    test('启动即为有网（首个事件 wifi）不触发', () {
      fakeAsync((async) {
        triggers = build()..attach();
        connectivity.add(const [ConnectivityResult.wifi]);
        async.flushMicrotasks();
        expect(syncCalls, isEmpty);
        triggers.detach();
      });
    });
  });
}
