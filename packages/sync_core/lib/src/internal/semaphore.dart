import 'dart:async';

/// 计数信号量：并发上限的内部实现件（传输队列下载/上传槽位、引擎拉取并发）。
class Semaphore {
  Semaphore(this.maxSlots) : _available = maxSlots;

  final int maxSlots;
  int _available;
  final List<void Function()> _waiters = [];

  /// 当前持有槽位数。
  int get active => maxSlots - _available;

  /// 历史峰值持有数（诊断/测试断言用）。
  int peak = 0;

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      _trackPeak();
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer.complete);
    return completer.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // 槽位直接移交下一个等待者：持有数不变，不归还池子。
      _waiters.removeAt(0)();
    } else {
      _available++;
    }
  }

  /// 在信号量保护下执行 [action]。
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }

  void _trackPeak() {
    if (active > peak) peak = active;
  }
}
