/// 坚果云引导式配置（FR-501，≤ 4 步）＋ WebDAV 通用模式（FR-502，P1）。
///
/// 步骤：
/// ① 图文说明生成应用密码（坚果云网页 → 安全选项 → 添加应用密码，
///    口令文案可复制）；
/// ② 输入账号 + 应用密码（密码框 obscure）；高级折叠项：自定义 WebDAV
///    地址/根目录（P1 功能提前放出的标注）；
/// ③ 自动连接测试（逐项显示：列目录/建目录/写读删/MOVE 延迟 ms）；
/// ④ 成功页（显示探测到的能力：MOVE/ETag/Range）→ 落凭据 → 返回。
///
/// 硬约束：密码框 obscure；测试过程与日志不落凭据（NFR-03）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/secure/secure_credential_store.dart';
import '../connection_test.dart';
import '../sync_facade.dart';

/// 坚果云引导页（`/sync/guide`）。
class JianguoYunGuidePage extends ConsumerStatefulWidget {
  const JianguoYunGuidePage({super.key});

  @override
  ConsumerState<JianguoYunGuidePage> createState() => _GuidePageState();
}

final class _GuidePageState extends ConsumerState<JianguoYunGuidePage> {
  int _currentStep = 0;

  final _accountController = TextEditingController();
  final _passwordController = TextEditingController();
  final _baseUrlController = TextEditingController(
    text: ConnectionTester.defaultBaseUrl,
  );
  final _rootPathController = TextEditingController(
    text: ConnectionTester.defaultRootPath,
  );

  bool _testing = false;
  ConnectionTestResult? _result;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    _rootPathController.dispose();
    super.dispose();
  }

  bool get _inputsValid =>
      _accountController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty;

  /// 步骤 ③：跑连接测试（进度态逐项显示）。
  Future<void> _runTest() async {
    setState(() {
      _testing = true;
      _result = null;
    });
    final tester = ConnectionTester();
    final result = await tester.test(
      baseUrl: _baseUrlController.text.trim(),
      username: _accountController.text.trim(),
      password: _passwordController.text,
      rootPath: _rootPathController.text.trim().isEmpty
          ? ConnectionTester.defaultRootPath
          : _rootPathController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
      if (result.success) _currentStep = 3;
    });
  }

  /// 步骤 ④：落凭据（安全存储）→ 重置引擎 → 返回。
  Future<void> _saveAndBack() async {
    final credentials = ref.read(secureCredentialStoreProvider);
    await credentials.save(
      SecureKeys.webdavAccount,
      _accountController.text.trim(),
    );
    await credentials.save(SecureKeys.webdavPassword, _passwordController.text);
    await credentials.save(
      SecureKeys.webdavBaseUrl,
      _baseUrlController.text.trim(),
    );
    await credentials.save(
      SecureKeys.webdavRootPath,
      _rootPathController.text.trim().isEmpty
          ? ConnectionTester.defaultRootPath
          : _rootPathController.text.trim(),
    );
    // 凭据已变：丢弃旧引擎，下一次同步按新适配器重建（Phase C 切换点生效处）。
    await ref.read(syncFacadeProvider).resetEngine();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配置坚果云同步')),
      body: Stepper(
        currentStep: _currentStep,
        type: StepperType.vertical,
        physics: const ClampingScrollPhysics(),
        onStepTapped: (step) => setState(() => _currentStep = step),
        onStepContinue: _onContinue,
        onStepCancel: _onCancel,
        controlsBuilder: (context, details) => _controls(context, details),
        steps: [_step1(), _step2(), _step3(), _step4()],
      ),
    );
  }

  /// 步进器"继续"：①→② 触发连接测试；④ 落凭据返回。
  Future<void> _onContinue() async {
    switch (_currentStep) {
      case 0:
        setState(() => _currentStep = 1);
      case 1:
        setState(() => _currentStep = 2);
        await _runTest();
      case 3:
        await _saveAndBack();
    }
  }

  void _onCancel() {
    if (_currentStep <= 0 || _testing) return;
    setState(() {
      _currentStep -= 1;
      if (_currentStep == 1) _result = null;
    });
  }

  Widget _controls(BuildContext context, ControlsDetails details) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: _testing
          ? const Row(
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('正在连接测试…'),
              ],
            )
          : Row(
              children: [
                if (_currentStep == 1)
                  FilledButton(
                    onPressed: _inputsValid ? details.onStepContinue : null,
                    child: const Text('开始连接测试'),
                  )
                else if (_currentStep == 3)
                  FilledButton(
                    onPressed: details.onStepContinue,
                    child: const Text('保存并返回'),
                  )
                else if (_currentStep == 2 &&
                    _result != null &&
                    !_result!.success) ...[
                  Text(
                    _result!.failureText ?? '连接失败',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: details.onStepContinue,
                    child: const Text('重试'),
                  ),
                ] else
                  const SizedBox.shrink(),
                const SizedBox(width: 8),
                if (_currentStep > 0 && _currentStep != 3)
                  TextButton(
                    onPressed: details.onStepCancel,
                    child: const Text('上一步'),
                  ),
              ],
            ),
    );
  }

  // ── 步骤 ①：生成应用密码说明 ──────────────────────────────────────────

  Step _step1() {
    return Step(
      title: const Text('生成应用密码'),
      isActive: _currentStep >= 0,
      state: _currentStep > 0 ? StepState.complete : StepState.indexed,
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _GuideLine('1. 浏览器打开坚果云网页版并登录'),
          _GuideLine('2. 进入「账户信息 → 安全选项」'),
          _GuideLine('3. 在「第三方应用管理」点击「添加应用密码」'),
          _GuideLine('4. 应用名称填 SyncReader，生成后复制口令'),
          SizedBox(height: 8),
          _CopyableCommand(),
          SizedBox(height: 8),
          Text(
            '应用密码与登录密码不同：仅开放 WebDAV 文件权限，可随时撤销。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  // ── 步骤 ②：账号 + 应用密码（含 FR-502 高级项）────────────────────────

  Step _step2() {
    return Step(
      title: const Text('输入账号与应用密码'),
      isActive: _currentStep >= 1,
      state: _currentStep > 1
          ? StepState.complete
          : _currentStep == 1
          ? StepState.indexed
          : StepState.disabled,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _accountController,
            decoration: const InputDecoration(
              labelText: '坚果云账号（邮箱）',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '应用密码',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          // FR-502：WebDAV 通用模式（P1 功能提前放出并标注）。
          _AdvancedWebDav(
            baseUrl: _baseUrlController,
            rootPath: _rootPathController,
          ),
        ],
      ),
    );
  }

  // ── 步骤 ③：自动连接测试 ──────────────────────────────────────────────

  Step _step3() {
    final result = _result;
    return Step(
      title: const Text('自动连接测试'),
      isActive: _currentStep >= 2,
      state: _testing
          ? StepState.editing
          : result == null
          ? StepState.indexed
          : result.success
          ? StepState.complete
          : StepState.error,
      content: result == null
          ? const Text('点击下方"开始连接测试"，将依次检查目录读写与 MOVE 能力。')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final step in result.steps)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Icon(
                          step.ok ? Icons.check_circle : Icons.cancel,
                          size: 16,
                          color: step.ok
                              ? Colors.green.shade600
                              : Theme.of(context).colorScheme.error,
                        ),
                        const SizedBox(width: 6),
                        Text(step.name),
                        const Spacer(),
                        Text(
                          step.latencyMs == null ? '-' : '${step.latencyMs} ms',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                if (!result.success) ...[
                  const SizedBox(height: 8),
                  Text(
                    result.failureText ?? '连接失败',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  // ── 步骤 ④：成功页 ────────────────────────────────────────────────────

  Step _step4() {
    final caps = _result?.capabilities;
    return Step(
      title: const Text('完成'),
      isActive: _currentStep >= 3,
      state: _currentStep > 3 ? StepState.complete : StepState.indexed,
      content: caps == null
          ? const Text('完成连接测试后保存配置。')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.verified,
                      color: Colors.green.shade600,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    const Text('连接成功'),
                  ],
                ),
                const SizedBox(height: 8),
                Text('MOVE 原子提交：${caps.supportsMove ? '支持' : '不支持（回退校验）'}'),
                Text(
                  'ETag 条件请求：${caps.supportsEtag ? '支持' : '不支持（size+mtime 合成）'}',
                ),
                Text('Range 断点续传：${caps.supportsRange ? '支持' : '不支持'}'),
              ],
            ),
    );
  }
}

/// 指引单行文案。
class _GuideLine extends StatelessWidget {
  const _GuideLine(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(text),
    );
  }
}

/// 可复制的应用名称口令。
class _CopyableCommand extends StatelessWidget {
  const _CopyableCommand();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('SyncReader', style: TextStyle(fontFamily: 'monospace')),
          IconButton(
            tooltip: '复制',
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: 'SyncReader'));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('已复制')));
              }
            },
          ),
        ],
      ),
    );
  }
}

/// FR-502 高级折叠项：自定义 WebDAV 地址/根目录（P1 功能标注）。
class _AdvancedWebDav extends StatelessWidget {
  const _AdvancedWebDav({required this.baseUrl, required this.rootPath});

  final TextEditingController baseUrl;
  final TextEditingController rootPath;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: const Text('高级：自定义 WebDAV 地址/根目录'),
        subtitle: const Text(
          'P1 功能（兼容其他 WebDAV 服务）',
          style: TextStyle(fontSize: 11),
        ),
        children: [
          _GuideTextField(controller: baseUrl, label: 'WebDAV 地址'),
          const SizedBox(height: 12),
          _GuideTextField(controller: rootPath, label: '同步根目录'),
        ],
      ),
    );
  }
}

/// 引导页输入框（受控）。
class _GuideTextField extends StatelessWidget {
  const _GuideTextField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
