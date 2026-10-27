import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/memory_webdav_server.dart';
import 'contract_suite.dart';

/// BackendAdapter 契约双跑（NFR-08 / CLAUDE.md §4.4）：同一套用例跑
/// WebDAV 适配器（真实 HTTP 语义，内存 WebDAV 服务器替身）。
///
/// 每个用例经 setUp 获得全新服务器实例（与 contract_suite_test.dart 的
/// 每用例工厂一致），互不残留。用例本体见 contract_suite.dart（未改动）。
void main() {
  contractSuite(() async {
    final server = await MemoryWebDavServer.start();
    addTearDown(server.close);

    final adapter = WebDavAdapter();
    await adapter.connect(
      BackendConfig(
        kind: BackendKind.webdav,
        baseUrl: server.uri.toString(),
        username: server.username,
        password: server.password,
        rootPath: '/Apps/SyncReader',
      ),
    );
    return adapter;
  }, tag: 'webdav');
}
