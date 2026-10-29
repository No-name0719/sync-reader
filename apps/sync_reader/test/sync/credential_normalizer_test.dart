/// 凭据规范化测试（v1.1 防"历史脏数据 + 新写入"两类 401 根因）：
///
/// 1. 规范化函数本身：去首尾空白 + 去零宽字符（U+200B~U+200D、U+FEFF），
///    **中间字符不动**（应用密码是 16 位全小写字母数字，中间无合法空格）；
/// 2. 读取侧（[SyncFacade.readConfigFrom]）：旧版本写入的脏数据（首尾空白、
///    零宽字符、baseUrl 尾斜杠）读出来一律是干净值；
/// 3. 未配置判定：账号/密码为空 → null（不返回半截配置）。
///
/// 写入侧（向导页落凭据）的规范化由向导页 widget 测试覆盖
/// （jianguoyun_guide_page_test.dart「落凭据规范化」）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/credential_normalizer.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

void main() {
  group('规范化函数', () {
    test('去首尾空白（含制表/换行）', () {
      expect(normalizeCredentialValue('  abc  '), 'abc');
      expect(normalizeCredentialValue('\t\nabc\r\n'), 'abc');
    });

    test('去零宽字符（U+200B / U+200C / U+200D / U+FEFF）', () {
      expect(normalizeCredentialValue('a\u200Bb'), 'ab');
      expect(normalizeCredentialValue('a\u200Cb'), 'ab');
      expect(normalizeCredentialValue('a\u200Db'), 'ab');
      expect(normalizeCredentialValue('a\uFEFFb'), 'ab');
    });

    test('中间字符不动（大小写 / 内部空格保留）', () {
      expect(normalizeCredentialValue('Ab Cd'), 'Ab Cd');
      expect(normalizeCredentialValue('a b\u200Bc'), 'a bc');
    });

    test('baseUrl 去尾斜杠（统一形态，避免拼出 //）', () {
      expect(
        normalizeBaseUrlValue('https://dav.example.com/dav/'),
        'https://dav.example.com/dav',
      );
      expect(
        normalizeBaseUrlValue('  https://dav.example.com/dav//  '),
        'https://dav.example.com/dav',
      );
      expect(normalizeBaseUrlValue(''), '');
    });

    test('rootPath 去首尾空白（保留前导 /）', () {
      expect(
        normalizeRootPathValue('  /Apps/SyncReader  '),
        '/Apps/SyncReader',
      );
    });
  });

  group('读取侧（readConfigFrom）', () {
    test('历史脏数据 → 返回规范化后的值', () async {
      final credentials = InMemoryCredentialStore();
      await credentials.save(
        SecureKeys.webdavAccount,
        '  user@example.com\u200B  ',
      );
      await credentials.save(SecureKeys.webdavPassword, '\uFEFFapp-pass \n');
      await credentials.save(
        SecureKeys.webdavBaseUrl,
        ' https://dav.example.com/dav/ ',
      );
      await credentials.save(SecureKeys.webdavRootPath, ' /Apps/SyncReader ');

      final config = await SyncFacade.readConfigFrom(credentials);
      expect(config, isNotNull);
      expect(config!.username, 'user@example.com');
      expect(config.password, 'app-pass');
      expect(config.baseUrl, 'https://dav.example.com/dav');
      expect(config.rootPath, '/Apps/SyncReader');
    });

    test('账号或密码为空 → null（未配置）', () async {
      final credentials = InMemoryCredentialStore();
      expect(await SyncFacade.readConfigFrom(credentials), isNull);

      await credentials.save(SecureKeys.webdavAccount, '   ');
      await credentials.save(SecureKeys.webdavPassword, 'app-pass');
      expect(
        await SyncFacade.readConfigFrom(credentials),
        isNull,
        reason: '空白账号等同于未配置',
      );

      await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
      await credentials.save(SecureKeys.webdavPassword, '\u200B');
      expect(
        await SyncFacade.readConfigFrom(credentials),
        isNull,
        reason: '仅零宽字符的密码等同于未配置',
      );
    });

    test('缺省 baseUrl / rootPath → 回落坚果云默认值', () async {
      final credentials = InMemoryCredentialStore();
      await credentials.save(SecureKeys.webdavAccount, 'user@example.com');
      await credentials.save(SecureKeys.webdavPassword, 'app-pass');
      final config = await SyncFacade.readConfigFrom(credentials);
      expect(config, isNotNull);
      expect(config!.baseUrl, 'https://dav.jianguoyun.com/dav/');
      expect(config.rootPath, '/Apps/SyncReader');
    });
  });
}
