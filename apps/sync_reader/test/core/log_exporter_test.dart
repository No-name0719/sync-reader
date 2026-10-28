/// LogExporter 测试（FR-604）：sanitizeAgain 二次脱敏规则表 +
/// exportTo 临时目录写盘集成用例。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// package_info_plus 为依赖树中的传递依赖（pubspec.yaml 冻结不可提升为直接依赖），
// 说明见 lib/core/log_exporter.dart。
// ignore: depend_on_referenced_packages
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sync_reader/core/app_logger.dart';
import 'package:sync_reader/core/log_exporter.dart';

void main() {
  setUp(() {
    AppLogger.clear();
    addTearDown(() {
      AppLogger.clear();
      LogExporter.packageInfoProvider = PackageInfo.fromPlatform;
    });
  });

  group('sanitizeAgain（FR-604 二次脱敏规则）', () {
    test('邮箱：本地部分掩码保留域名（account= 与纯文本两种形态）', () {
      expect(
        LogExporter.sanitizeAgain('坚果云登录成功 abc@example.com'),
        '坚果云登录成功 abc***@example.com',
      );
      expect(
        LogExporter.sanitizeAgain('account=longlocal@corp.example.io'),
        'account=lon***@corp.example.io',
      );
      // 本地部分不足 3 位全保留。
      expect(LogExporter.sanitizeAgain('账号 ab@x.cn'), '账号 ab***@x.cn');
    });

    test('URL 内嵌凭据：scheme://user:pass@host → scheme://***@host', () {
      final out = LogExporter.sanitizeAgain(
        '连接 https://alice:s3cret-pass@dav.jianguoyun.com/dav/ 失败',
      );
      expect(out, '连接 https://***@dav.jianguoyun.com/dav/ 失败');
      expect(out, isNot(contains('alice')));
      expect(out, isNot(contains('s3cret-pass')));
    });

    test('40 位以上十六进制 → ***（含 sha256:<64hex>，注释取舍）', () {
      final hex40 = '0123456789abcdef0123456789abcdef01234567';
      final out = LogExporter.sanitizeAgain('刷新令牌 $hex40 已失效');
      expect(out, '刷新令牌 *** 已失效');
      // sha256:<64hex> 属书库元数据而非机密，但可从本地正文重算，
      // 导出件宁可不带，故为简单一致也打码。
      expect(
        LogExporter.sanitizeAgain('contentHash=sha256:${'a' * 64}'),
        'contentHash=sha256:***',
      );
    });

    test('32 位以上 base64url 连续串 → ***', () {
      final b64 = 'QWxhZGRpbjpvcGVuIHNlc2FtZQ'; // 26 位不受影响（ULID 同级）
      expect(LogExporter.sanitizeAgain('段落指纹 $b64 跳过'), '段落指纹 $b64 跳过');
      final long = 'cGFzc3dvcmQxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMzQ1Njc4OTA';
      final out = LogExporter.sanitizeAgain('收到的令牌 $long 已校验');
      expect(out, '收到的令牌 *** 已校验');
    });

    test('Bearer/Basic 后随串 → ***（一级覆盖之上的兜底）', () {
      final out = LogExporter.sanitizeAgain(
        'Authorization: Bearer top-secret-token',
      );
      expect(out, 'Authorization: Bearer ***');
      expect(out, isNot(contains('top-secret-token')));
      expect(
        LogExporter.sanitizeAgain(
          'PUT /dav/ with Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==',
        ),
        contains('Basic ***'),
      );
    });

    test('普通中文行不受影响', () {
      const plain = '第三章 分页完成，耗时 12ms，bookId=01A,locator={type:raw}';
      expect(LogExporter.sanitizeAgain(plain), plain);
    });

    test('一级 + 二级叠加：redactCredentials 漏掉的邮箱由 sanitizeAgain 收口', () {
      const raw = '账号 user@mail.com 密码 password=abc123';
      final once = AppLogger.redactCredentials(raw);
      expect(once, contains('password=***')); // 一级：凭据键打码。
      final twice = LogExporter.sanitizeAgain(once);
      expect(twice, isNot(contains('abc123')));
      expect(twice, isNot(contains('user@mail.com')));
      expect(twice, contains('use***@mail.com')); // 二级：纯文本邮箱打码。
    });
  });

  group('exportTo 临时目录集成（FR-604）', () {
    late Directory tmpDir;
    final info = PackageInfo(
      appName: 'sync_reader',
      packageName: 'com.example.sync_reader',
      version: '9.9.9',
      buildNumber: '42',
    );

    setUp(() async {
      LogExporter.packageInfoProvider = () async => info;
      tmpDir = await Directory.systemTemp.createTemp('syncr_logexp');
      addTearDown(() => tmpDir.delete(recursive: true));
    });

    test('写入头部（版本/平台/时间/行数）与二次脱敏正文，返回行数', () async {
      final log = AppLogger();
      log.info('同步完成 account=reader@example.com');
      log.error('上传失败 password=TopS3cret');

      final file = File('${tmpDir.path}/log.txt');
      final lineCount = await LogExporter.exportTo(file.path);

      expect(lineCount, 2);
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('应用版本：9.9.9+42'));
      expect(content, contains('平台：${Platform.operatingSystem}'));
      expect(content, contains('导出时间：'));
      expect(content, contains('日志行数：2'));
      // 二次脱敏正文：邮箱与凭据均不可见。
      expect(content, contains('rea***@example.com'));
      expect(content, isNot(contains('reader@example.com')));
      expect(content, isNot(contains('TopS3cret')));
      expect(content, contains('password=***'));
    });

    test('savePath 为 null（用户取消）返回 null 且不写任何文件', () async {
      AppLogger().info('不该落盘');
      expect(await LogExporter.exportTo(null), isNull);
      expect(tmpDir.listSync(), isEmpty);
    });

    test('空缓冲导出：仅头部，行数为 0', () async {
      final file = File('${tmpDir.path}/empty.txt');
      final lineCount = await LogExporter.exportTo(file.path);
      expect(lineCount, 0);
      final content = file.readAsStringSync();
      expect(content, contains('日志行数：0'));
    });
  });
}
