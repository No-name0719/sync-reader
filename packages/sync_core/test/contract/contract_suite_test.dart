/// BackendAdapter 契约测试（NFR-08）：同一套用例双端执行。
///
/// M2 实现 WebDAV 适配器后，在本目录新建 `webdav_test.dart`：
///
/// ```dart
/// import 'contract_suite.dart';
///
/// void main() {
///   runBackendAdapterContractSuite(() async {
///     final adapter = WebDavAdapter();
///     await adapter.connect(BackendConfig(/* 测试网盘/本地 WebDAV 容器 */));
///     return adapter;
///   });
/// }
/// ```
///
/// M3 实现 REST 适配器后同理新建 `rest_test.dart`（CI 起服务端容器）。
/// 用例清单与落地步骤见 `contract_suite.dart` 头注释。
void main() {}
