/// 坚果云引导页 widget 测试（FR-501 步骤导航）：
/// - 每步都有「上一步/下一步」按钮；步骤 1 输入不合法时下一步禁用；
/// - 未到达的步骤头部不可点跳（防跳过输入直接到测试）；
/// - 连接测试成功自动进步骤 3（保留原流转），失败显示「重新测试」；
/// - 完成落凭据（InMemoryCredentialStore，不触碰真实安全存储）→ 返回。
///
/// 网络说明：testWidgets 环境下 HttpClient 被 flutter_test 全局拦截（一律
/// 400），无法访问真实 socket；本套件经 HttpOverrides 注入假 WebDAV 客户端
/// （按方法/Basic 凭据返回协议状态码），覆盖"测试成功/401 失败"两条路径。
///
/// 注：竖向 Stepper 会为每个步骤都构建 controls（仅当前步可见、可命中），
/// 断言/点击一律经 `guide-controls-{step}` key 定位当前步那份。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sync_reader/app/providers.dart';
import 'package:sync_reader/data/db/app_database.dart';
import 'package:sync_reader/data/secure/secure_credential_store.dart';
import 'package:sync_reader/features/sync/pages/jianguoyun_guide_page.dart';
import 'package:sync_reader/features/sync/sync_facade.dart';

/// 测试账号（假服务端的正确凭据）。
const _account = 'user@example.com';
const _password = 'app-pass';

/// 第 [step] 步 controls 的 key（竖向 Stepper 为每步都构建 controls，
/// 仅当前步可见、可命中，故断言/点击一律经 key 定位当前步那份）。
Key _controlsKey(int step) => ValueKey('guide-controls-$step');

/// 当前步 controls 内的文案 finder（区别于隐藏副本）。
Finder controlText(String label, int step) => find.descendant(
  of: find.byKey(_controlsKey(step)),
  matching: find.text(label),
);

/// 当前步 controls 内的主按钮（FilledButton）。
Finder controlButton(String label, int step) => find.descendant(
  of: find.byKey(_controlsKey(step)),
  matching: find.byType(FilledButton),
);

void main() {
  late AppDatabase db;
  late InMemoryCredentialStore credentials;

  /// 注入假 WebDAV 客户端（恢复 flutter_test 自身的 HttpOverrides）。
  void installFakeWebDav({bool authOk = true}) {
    final original = HttpOverrides.current;
    HttpOverrides.global = _WebDavSuccessOverrides(
      expectCredentials: authOk ? '$_account:$_password' : '$_account:other',
    );
    addTearDown(() => HttpOverrides.global = original);
  }

  Future<void> pumpGuide(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        secureCredentialStoreProvider.overrideWithValue(credentials),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _OpenerPage()),
      ),
    );
    await tester.pump();
    // 进入引导页。
    await tester.tap(find.text('open-guide'));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').getSingle();
    credentials = InMemoryCredentialStore();
  });

  tearDown(() async {
    await db.close();
  });

  /// 填入账号 + 应用密码（步骤 1 的两个输入框）。
  Future<void> fillInputs(
    WidgetTester tester, {
    String account = _account,
    String password = _password,
  }) async {
    await tester.enterText(
      find.widgetWithText(TextField, '坚果云账号（邮箱）'),
      account,
    );
    await tester.enterText(find.widgetWithText(TextField, '应用密码'), password);
    await tester.pump();
  }

  testWidgets('步骤 0：只有「开始配置」，无「上一步」；未到达步骤头部不可跳', (tester) async {
    await pumpGuide(tester);

    expect(
      tester.widget<FilledButton>(controlButton('开始配置', 0)).onPressed,
      isNotNull,
    );
    expect(controlText('上一步', 0), findsNothing);
    expect(controlText('下一步', 0), findsNothing);

    // 点未到达的头部（"完成"）：不允许跳过。
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(controlText('开始配置', 0), findsOneWidget, reason: '仍停在步骤 0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('步骤 1：上一步/下一步成对出现；输入不合法时下一步禁用', (tester) async {
    await pumpGuide(tester);
    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();

    expect(controlText('上一步', 1), findsOneWidget);
    expect(
      tester.widget<FilledButton>(controlButton('下一步', 1)).onPressed,
      isNull,
      reason: '未输入时禁用',
    );

    // 上一步回步骤 0。
    await tester.tap(controlText('上一步', 1));
    await tester.pumpAndSettle();
    expect(controlText('开始配置', 0), findsOneWidget);

    // 再次进入：输入合法后下一步可用。
    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester);
    expect(
      tester.widget<FilledButton>(controlButton('下一步', 1)).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('步骤 2→3：连接测试成功自动进成功页，「完成」落凭据并返回', (tester) async {
    installFakeWebDav(authOk: true);
    await pumpGuide(tester);
    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester);

    await tester.tap(controlButton('下一步', 1));
    await tester.pumpAndSettle();

    // 测试成功：自动流转到成功页（步骤 3），能力与「完成」按钮可见。
    expect(find.text('连接成功'), findsOneWidget);
    expect(find.textContaining('MOVE 原子提交'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(controlButton('完成', 3)).onPressed,
      isNotNull,
    );

    // 完成：落凭据 → 重置引擎 → 返回引导入口页。
    await tester.tap(controlButton('完成', 3));
    await tester.pumpAndSettle();
    expect(find.text('open-guide'), findsOneWidget, reason: '引导页已 pop');
    expect(await credentials.read(SecureKeys.webdavAccount), _account);
    expect(await credentials.read(SecureKeys.webdavPassword), _password);
    expect(
      await credentials.read(SecureKeys.webdavBaseUrl),
      'https://dav.jianguoyun.com/dav/',
      reason: '未改动高级项时保持默认地址',
    );
  });

  testWidgets('步骤 2 失败（401）：留在本步显示「重新测试」；上一步清空结果', (tester) async {
    // 填错的应用密码 → 假服务端 401。
    installFakeWebDav(authOk: false);
    await pumpGuide(tester);
    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester, password: 'wrong-pass');

    await tester.tap(controlButton('下一步', 1));
    await tester.pumpAndSettle();

    expect(find.text('连接成功'), findsNothing);
    // 行内 detail（HTTP 401）与分类文案（密码错误…HTTP 401：请核对后重新输入…）各一处。
    expect(find.text('HTTP 401'), findsOneWidget);
    expect(find.textContaining('密码错误或账号无效'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(controlButton('重新测试', 2)).onPressed,
      isNotNull,
      reason: '失败后可重新测试',
    );

    // 上一步回到输入步（连接结果清空），再进来按钮回到「开始连接测试」。
    await tester.tap(controlText('上一步', 2));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 401'), findsNothing, reason: '回退清空结果');
    expect(find.textContaining('密码错误或账号无效'), findsNothing);
    await tester.tap(find.text('自动连接测试'));
    await tester.pumpAndSettle();
    expect(controlText('开始连接测试', 2), findsOneWidget);
  });

  testWidgets('成功后可经「上一步」回测试步（保留结果，按钮变「重新测试」）', (tester) async {
    installFakeWebDav(authOk: true);
    await pumpGuide(tester);
    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester);
    await tester.tap(controlButton('下一步', 1));
    await tester.pumpAndSettle();
    expect(find.text('连接成功'), findsOneWidget);

    await tester.tap(controlText('上一步', 3));
    await tester.pumpAndSettle();
    expect(controlButton('重新测试', 2), findsOneWidget);

    // 已到达过的步骤可经头部点击回跳：点"输入账号"标题回到步骤 1。
    await tester.tap(find.text('输入账号与应用密码'));
    await tester.pumpAndSettle();
    expect(controlText('下一步', 1), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('480x800 窄窗：全流程无溢出异常（floating 标签可见）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installFakeWebDav(authOk: true);
    await pumpGuide(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(controlButton('下一步', 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('连接成功'), findsOneWidget);
  });

  testWidgets('1280x800 宽窗：全流程无溢出异常', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    installFakeWebDav(authOk: true);
    await pumpGuide(tester);
    expect(tester.takeException(), isNull);

    await tester.tap(controlButton('开始配置', 0));
    await tester.pumpAndSettle();
    await fillInputs(tester);
    await tester.tap(controlButton('下一步', 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('连接成功'), findsOneWidget);
  });
}

// ── 假 WebDAV 客户端（HttpOverrides 级，协议状态码按方法返回）────────────

/// 按方法返回连接测试所需的协议状态码；[expectCredentials] 非空时校验
/// Basic 凭据（`account:password` 全等，不匹配 → 401），覆盖"密码错误"
/// 分类文案路径。
class _WebDavSuccessOverrides extends HttpOverrides {
  _WebDavSuccessOverrides({this.expectCredentials});

  /// 非空 = 要求 Basic 凭据与之全等，否则 401。
  final String? expectCredentials;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _FakeHttpClient(this);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._overrides);

  final _WebDavSuccessOverrides _overrides;

  @override
  set connectionTimeout(Duration? timeout) {}

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _FakeRequest(method, _overrides);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.method, this.overrides);

  @override
  final String method;
  final _WebDavSuccessOverrides overrides;
  @override
  final _FakeHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async {
    // Basic 凭据校验（期望凭据已配置且不匹配 → 401，模拟坚果云密码错误）。
    final expectCredentials = overrides.expectCredentials;
    if (expectCredentials != null) {
      final auth = headers.value('authorization') ?? '';
      final decoded = () {
        try {
          return utf8.decode(base64.decode(auth.substring(6).trim()));
        } on Object {
          return '';
        }
      }();
      if (decoded != expectCredentials) {
        return _FakeResponse(status: 401);
      }
    }
    switch (method) {
      case 'PROPFIND':
        return _FakeResponse(status: 207);
      case 'GET':
        return _FakeResponse(
          status: headers.value('range') == null ? 200 : 206,
          etag: '"fake-etag"',
        );
      case 'MOVE':
        return _FakeResponse(status: 201);
      case 'DELETE':
        return _FakeResponse(status: 204);
      default: // MKCOL / PUT → 201。
        return _FakeResponse(status: 201);
    }
  }

  @override
  void add(List<int> data) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> _values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = value.toString();

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  set contentLength(int length) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.status, String? etag}) {
    if (etag != null) headers.set('etag', etag);
  }

  final int status;
  @override
  final _FakeHeaders headers = _FakeHeaders();

  @override
  int get statusCode => status;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> element)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  // 其余 HttpClientResponse 成员（redirect/certificate 等）连接测试不使用。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 引导入口宿主页：保证引导页不是根路由（「完成」可 pop 回来）。
class _OpenerPage extends StatelessWidget {
  const _OpenerPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const JianguoYunGuidePage(),
            ),
          ),
          child: const Text('open-guide'),
        ),
      ),
    );
  }
}
