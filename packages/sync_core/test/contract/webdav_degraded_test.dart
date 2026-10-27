import 'package:sync_core/sync_core.dart';
import 'package:test/test.dart';

import '../support/memory_webdav_server.dart';
import 'contract_suite.dart';

/// 契约双跑·降级形态（docs/04 §8.1）：同一套契约用例对
/// "无 ETag + 禁 MOVE"的服务器再跑一遍——
/// - supportsEtag=false → etag 以 `synthetic-{size}-{mtimeMs}` 合成，
///   条件请求退化为"200 + etag 相同按未变更处理"；
/// - supportsMove=false → 上传直写目标位 + Content-Length 校验兜底。
void main() {
  contractSuite(() async {
    final server = await MemoryWebDavServer.start(
      enableEtag: false,
      enableMove: false,
      // 顺带验证解析的命名空间容错：无前缀（默认命名空间）multistatus。
      propfindPrefix: '',
    );
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
  }, tag: 'webdav-degraded');
}
