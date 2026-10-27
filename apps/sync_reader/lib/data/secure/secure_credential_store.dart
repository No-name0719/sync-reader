/// 凭据安全存储（docs/03 §4.4 CredentialStore，FR-504）。
///
/// - 实现 [CredentialStore]：flutter_secure_storage 封装，平台后端自动生效
///   （Android=Keystore / Windows=DPAPI / iOS=Keychain，docs/03 §5）；
/// - 密钥命名空间见 [SecureKeys]：baseUrl/rootPath 非机密，但与凭据放在一起
///   便于"清除凭据"一次清空（可接受，docs/04 §9）；
/// - 硬约束：凭据零落 SQLite/日志/崩溃报告（NFR-03）——日志层默认脱敏钩子
///   见 AppLogger.redactCredentials，本层自身绝不输出值。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 密钥命名空间（docs/03 §4.4 的 key 约定）。
abstract final class SecureKeys {
  /// 首次启动生成的设备 ULID（冲突决胜第三位，docs/04 §2）。
  static const String deviceId = 'device.id';

  /// WebDAV 账号（坚果云用户名）。
  static const String webdavAccount = 'webdav.account';

  /// WebDAV 应用密码（机密，只进安全存储）。
  static const String webdavPassword = 'webdav.password';

  /// WebDAV 服务地址（非机密；随凭据一起存便于整体清除）。
  static const String webdavBaseUrl = 'webdav.baseUrl';

  /// 同步根目录（非机密；随凭据一起存便于整体清除）。
  static const String webdavRootPath = 'webdav.rootPath';
}

/// 凭据存取接口（docs/03 §4.4）。
///
/// 实现约束：禁止写入 SQLite、日志、崩溃报告（NFR-03）。
abstract interface class CredentialStore {
  /// 保存（已存在则覆盖）。
  Future<void> save(String key, String secret);

  /// 读取；不存在返回 null。
  Future<String?> read(String key);

  /// 删除单个密钥。
  Future<void> delete(String key);

  /// 清空全部密钥（"清除凭据"危险区操作）。
  Future<void> deleteAll();
}

/// [CredentialStore] 的 flutter_secure_storage 实现。
///
/// 平台后端由插件自动选择（Windows=DPAPI、Android=Keystore、iOS=Keychain）。
final class SecureCredentialStore implements CredentialStore {
  /// 构造；可注入 [FlutterSecureStorage] 便于定制平台选项。
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> save(String key, String secret) =>
      _storage.write(key: key, value: secret);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

/// 内存实现：仅供测试与依赖注入（生产一律用 [SecureCredentialStore]）。
final class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  /// 只读快照（测试断言用）。
  Map<String, String> get values => Map.unmodifiable(_values);

  @override
  Future<void> save(String key, String secret) async {
    _values[key] = secret;
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _values.clear();
  }
}
