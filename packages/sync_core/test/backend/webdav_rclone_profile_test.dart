/// rclone 真实行为画像测试（R3 联调专用，默认 CI 跳过）。
///
/// 与 `tool/rclone_probe.dart` 读同一份 rclone 路径环境变量
/// `SYNC_RCLONE_DIR`（rclone.exe 所在目录；缺省回退仓库
/// `.tools/rclone/rclone-v1.71.2-windows-amd64`）。本地执行：
/// ```
/// SYNC_RCLONE_DIR=<rclone 目录> dart test test/backend/webdav_rclone_profile_test.dart
/// ```
///
/// 断言值来自 2026-10-27 对 rclone v1.71.2（windows amd64，`serve webdav`
/// 本地目录后端）的实测画像（探针输出）：
/// - ETag：强 ETag、带引号、18 位 hex（非 MD5/SHA 长度）——适配器按
///   "etag 由内容决定"消费，绝不能假设 etag=MD5（那是坚果云特征）；
/// - If-None-Match 命中 → 304（条件请求生效）；
/// - MOVE → 201（tmp→MOVE 原子上传可用）；
/// - Range `bytes=0-0` → 206 + `Content-Range: bytes 0-0/<total>`
///   （断点续传可用）；
/// - PROPFIND XML 用大写 `D:` 前缀 + `xmlns:D="DAV:"`；
/// - 本地服务器不限流：观察不到 429/503 + Retry-After（该路径由内存
///   服务器的故障注入用例覆盖）。
///
/// 跳过语义：未找到 rclone（CI 无网/未解压）→ `markTestSkipped` 默认跳过；
/// 本地设置 `SYNC_RCLONE_DIR` 后真实执行。
library;

import 'package:test/test.dart';

import '../../tool/rclone_probe.dart';

void main() {
  test('rclone serve webdav 行为画像（v1.71.2 实测基线）', () async {
    // 未找到 rclone（CI 默认环境）→ 跳过；SYNC_RCLONE_DIR 指向本地
    // rclone 后真实执行（R3 联调）。
    if (resolveRcloneExe() == null) {
      markTestSkipped('需本地 rclone，R3 联调用（未设置 SYNC_RCLONE_DIR）');
      // markTestSkipped 只标记状态、不中断用例体，必须显式 return，
      // 否则会继续跑探针并抛 StateError（用例变成失败而非跳过）。
      return;
    }
    final summary = await runRcloneProbe();

    // 服务器确实启动（探针自管）。
    expect(summary.serverVersion, startsWith('rclone v'));

    // ETag：有、带引号、非空（rclone local 后端为 18 位 hex 截断摘要，
    // 只断言"引号强 ETag"这一稳定特征，长度不设防）。
    expect(summary.etagHeader, isNotNull);
    expect(summary.etagHeader!.trim(), startsWith('"'));
    expect(summary.etagFormat, isNot(contains('MD5')));

    // 条件请求与原子提交：304 / MOVE 全支持。
    expect(summary.supports304, isTrue, reason: 'If-None-Match 命中应返回 304');
    expect(summary.supportsMove, isTrue, reason: 'MOVE 应成功（tmp→MOVE 上传）');
    expect(summary.moveStatus, inInclusiveRange(200, 299));

    // 断点续传：Range → 206 + Content-Range 总长。
    expect(summary.supportsRange, isTrue);
    expect(summary.contentRangeSample, matches(RegExp(r'^bytes 0-0/\d+$')));

    // PROPFIND 前缀风格：rclone 用大写 D:（适配器解析器必须容忍）。
    expect(summary.propfindPrefixStyle, contains('D:'));

    // 适配器自探测与实测一致：三能力全开 → 走最优路径。
    expect(summary.capabilities.supportsMove, isTrue);
    expect(summary.capabilities.supportsEtag, isTrue);
    expect(summary.capabilities.supportsRange, isTrue);

    // 功能面：清单非空、删除生效（逐项检查由探针内部完成并打印）。
    expect(summary.checks['PUT/GET meta'], isNot(contains('FAIL')));
    expect(summary.checks['tmp→MOVE 上传'], contains('OK'));
    expect(summary.checks['Range 续传（适配器）'], contains('OK'));
    expect(summary.checks['DELETE'], contains('OK'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
