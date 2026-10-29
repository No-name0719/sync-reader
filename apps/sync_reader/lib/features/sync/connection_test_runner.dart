/// 连接测试执行入口（可注入；FR-505 连接测试的可替换 seam）。
///
/// [ConnectionTester] 是 final class（不可子类化），因此把"跑一次测试"
/// 这件事抽成函数类型 + Riverpod provider：
/// - 生产实现 = 直接调 [ConnectionTester.test]（真实 WebDAV 往返）；
/// - 测试里整体覆盖为假实现（断言"点了按钮确实发起了测试"，不碰网络）。
///
/// 硬约束：凭据只作为参数穿过本层，绝不进入结果文案或日志（NFR-03）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_test.dart';

/// 连接测试执行函数（参数与 [ConnectionTester.test] 对齐）。
///
/// [rootPath] 为 null 时按 [ConnectionTester.defaultRootPath] 处理。
typedef ConnectionTestRunner = Future<ConnectionTestResult> Function({
  required String baseUrl,
  required String username,
  required String password,
  String? rootPath,
});

/// 生产实现：真实 WebDAV 往返（每次调用新建 [ConnectionTester]）。
Future<ConnectionTestResult> defaultConnectionTestRunner({
  required String baseUrl,
  required String username,
  required String password,
  String? rootPath,
}) {
  return ConnectionTester().test(
    baseUrl: baseUrl,
    username: username,
    password: password,
    rootPath: rootPath ?? ConnectionTester.defaultRootPath,
  );
}

/// 连接测试执行入口 provider（同步设置页 + 向导页共用；测试可覆盖）。
final connectionTestRunnerProvider = Provider<ConnectionTestRunner>(
  (ref) => defaultConnectionTestRunner,
);
