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
/// A12b：旧版 Material `Stepper` 改为自绘**四步进度轨**（完成 ✓ / 当前高亮
/// / 未开始灰，对齐原型 guide 屏）；步骤语义与流转逻辑保持不变；表单为
/// 标签 + 输入框 + 提示条样式。
///
/// 硬约束：密码框 obscure；测试过程与日志不落凭据（NFR-03）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_core/sync_core.dart';

import '../../../core/design_tokens.dart';
import '../../../data/secure/secure_credential_store.dart';
import '../../../shared/copy.dart';
import '../connection_test.dart';
import '../connection_test_result_view.dart';
import '../connection_test_runner.dart';
import '../credential_normalizer.dart';
import '../sync_facade.dart';

/// 引导页步骤数（四步进度轨固定）。
const int _kStepCount = 4;

/// 步骤轨一态：完成 / 当前 / 未开始。
enum _TrackStepState { done, current, pending }

/// 坚果云引导页（`/sync/guide`）。
class JianguoYunGuidePage extends ConsumerStatefulWidget {
  const JianguoYunGuidePage({super.key});

  @override
  ConsumerState<JianguoYunGuidePage> createState() => _GuidePageState();
}

final class _GuidePageState extends ConsumerState<JianguoYunGuidePage> {
  int _currentStep = 0;

  /// 历史上到达过的最远步骤：头部点击只允许跳到已到达的步骤，
  /// 未到达的未来步骤置 disabled（不可点），避免跳过输入直接到测试。
  int _maxVisitedStep = 0;

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

  /// 第 1 步的图文指引是否展开（默认收起，点「图文指引」按钮展开）。
  bool _showImageGuide = false;

  /// 是否已有保存的配置（true = 顶部显示「使用已保存的配置测试」快捷卡）。
  bool _hasSavedConfig = false;

  /// 已保存配置的展示信息（账号 · 根目录；不含密码）。
  String _savedAccount = '';
  String _savedRootPath = '';

  /// 「使用已保存的配置测试」进行中。
  bool _savedTesting = false;

  /// 「使用已保存的配置测试」结果（复用共享结果组件）。
  ConnectionTestResult? _savedResult;

  /// 已保存的配置读不到（提示并引导回第 2 步填写）。
  bool _savedConfigMissing = false;

  @override
  void initState() {
    super.initState();
    _loadSavedConfig();
  }

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    _baseUrlController.dispose();
    _rootPathController.dispose();
    super.dispose();
  }

  /// 读已保存的配置（只读凭据，不装配引擎）。
  Future<void> _loadSavedConfig() async {
    final config = await _readSavedConfig();
    if (!mounted) return;
    setState(() {
      _hasSavedConfig = config != null;
      _savedAccount = config?.username ?? '';
      _savedRootPath = config?.rootPath ?? '';
    });
  }

  /// 读已保存配置（返回 null = 未配置或读不到）。
  Future<BackendConfig?> _readSavedConfig() async {
    try {
      return await SyncFacade.readConfigFrom(
        ref.read(secureCredentialStoreProvider),
      );
    } catch (_) {
      return null;
    }
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
    ConnectionTestResult result;
    try {
      result = await ref.read(connectionTestRunnerProvider)(
        baseUrl: _baseUrlController.text.trim(),
        username: normalizeCredentialValue(_accountController.text),
        password: normalizeCredentialValue(_passwordController.text),
        rootPath: _rootPathController.text.trim().isEmpty
            ? ConnectionTester.defaultRootPath
            : _rootPathController.text.trim(),
      );
    } catch (_) {
      result = const ConnectionTestResult(
        steps: [],
        success: false,
        failureText: kConnectionTestExceptionText,
      );
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = result;
      // 测试成功自动流转到成功页（保留原行为）；同步更新最远到达步。
      if (result.success) {
        _currentStep = 3;
        if (_maxVisitedStep < 3) _maxVisitedStep = 3;
      }
    });
  }

  /// 「使用已保存的配置测试」：不填表，直接跑第 3 步的连接测试。
  ///
  /// **只测不改**：不写凭据、不动已保存配置；结果就地显示在快捷卡内
  /// （与同步设置页共用同一套结果组件）。已保存配置读不到 → 提示并引导
  /// 回第 2 步填写。
  Future<void> _runSavedTest() async {
    if (_savedTesting) return;
    setState(() {
      _savedTesting = true;
      _savedResult = null;
      _savedConfigMissing = false;
    });
    final config = await _readSavedConfig();
    if (config == null) {
      if (!mounted) return;
      setState(() {
        _savedTesting = false;
        _savedConfigMissing = true;
      });
      return;
    }
    ConnectionTestResult result;
    try {
      result = await ref.read(connectionTestRunnerProvider)(
        baseUrl: config.baseUrl,
        username: config.username ?? '',
        password: config.password ?? '',
        rootPath: config.rootPath,
      );
    } catch (_) {
      result = const ConnectionTestResult(
        steps: [],
        success: false,
        failureText: kConnectionTestExceptionText,
      );
    }
    if (!mounted) return;
    setState(() {
      _savedTesting = false;
      _savedResult = result;
    });
  }

  /// 步骤 ④：落凭据（安全存储）→ 重置引擎 → 返回。
  ///
  /// 写入前做**凭据规范化**（账号/密码去首尾空白 + 零宽字符；中间字符不
  /// 动）：坚果云应用密码是 16 位全小写字母数字，粘贴时带入的空格/零宽
  /// 字符会让服务端按字节比对失败 → 401。
  Future<void> _saveAndBack() async {
    final credentials = ref.read(secureCredentialStoreProvider);
    await credentials.save(
      SecureKeys.webdavAccount,
      normalizeCredentialValue(_accountController.text),
    );
    await credentials.save(
      SecureKeys.webdavPassword,
      normalizeCredentialValue(_passwordController.text),
    );
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
    // pop(true)：告诉调用方「配置已保存」。首启引导页据此判定首启完成
    // （docs/10 §4.9）；同步设置页的入口忽略返回值，行为不变。
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('配置坚果云同步')),
      // 居中限宽（原型 guide 屏 content-inner max-width: 760px）。
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s6,
              AppSpacing.s6,
              AppSpacing.s6,
              AppSpacing.s12,
            ),
            children: [
              _TrackCard(
                currentStep: _currentStep,
                maxVisitedStep: _maxVisitedStep,
                onStepTapped: _onStepTapped,
              ),
              const SizedBox(height: AppSpacing.s4),
              // 「已保存配置」快捷卡（不填表直接测）：与四步进度轨分开，
              // 已有保存配置时才出现。
              if (_hasSavedConfig) ...[
                _SavedConfigCard(
                  account: _savedAccount,
                  rootPath: _savedRootPath,
                  testing: _savedTesting,
                  result: _savedResult,
                  missing: _savedConfigMissing,
                  onTest: _runSavedTest,
                  onFill: () => _goto(1),
                ),
                const SizedBox(height: AppSpacing.s4),
              ],
              _ContentCard(
                currentStep: _currentStep,
                controls: KeyedSubtree(
                  // 与旧版一致：控件区按步骤索引加 key，测试精确定位当前步。
                  key: ValueKey('guide-controls-$_currentStep'),
                  child: _controls(context),
                ),
                content: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: KeyedSubtree(
                    key: ValueKey('guide-content-$_currentStep'),
                    child: _stepContent(_currentStep),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 前进到目标步骤（记录最远到达步；测试中不接受前进）。
  void _goto(int step) {
    if (_testing) return;
    setState(() {
      _currentStep = step;
      if (step > _maxVisitedStep) _maxVisitedStep = step;
    });
  }

  /// 步进器"继续"：①→② 输入；②→③ 触发连接测试；③ 失败可重新测试；
  /// ④ 落凭据返回（成功页自动流转由 [_runTest] 完成）。
  Future<void> _onContinue() async {
    switch (_currentStep) {
      case 0:
        _goto(1);
      case 1:
        if (!_inputsValid) return;
        _goto(2);
        await _runTest();
      case 2:
        // 首次进入已由 ② 触发；此处为失败后"重新测试"或回退后补测。
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

  /// 步骤头部点击：只允许跳到已到达过的步骤（未到达步骤头部为 disabled，
  /// 这里再过滤一次作双保险）。
  void _onStepTapped(int step) {
    if (_testing || step > _maxVisitedStep || step == _currentStep) return;
    setState(() {
      _currentStep = step;
      // 回到输入步 = 放弃本次测试结果（与"上一步"语义一致）。
      if (step == 1) _result = null;
    });
  }

  /// 当前步控件区：测试中只显示进度行（防重复触发）；否则主按钮 + 上一步。
  Widget _controls(BuildContext context) {
    if (_testing) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('正在连接测试…'),
          ],
        ),
      );
    }
    // 每步都有明确的「下一步」主按钮（步骤 1 需输入合法才可用）。
    final (label, enabled) = switch (_currentStep) {
      0 => ('开始配置', true),
      1 => ('下一步', _inputsValid),
      2 => (_result == null ? '开始连接测试' : '重新测试', true),
      _ => ('完成', true),
    };
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_currentStep > 0)
            TextButton(onPressed: _onCancel, child: const Text('上一步')),
          const SizedBox(width: AppSpacing.s2),
          FilledButton(
            onPressed: enabled ? _onContinue : null,
            child: Text(label),
          ),
        ],
      ),
    );
  }

  // ── 步骤内容（语义沿用旧 Stepper 版本，仅视觉重排）────────────────────

  Widget _stepContent(int step) {
    switch (step) {
      case 0:
        return _step1();
      case 1:
        return _step2();
      case 2:
        return _step3();
      default:
        return _step4();
    }
  }

  // ── 步骤 ①：生成应用密码说明 ──────────────────────────────────────────

  Widget _step1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _GuideLine('1. 下载并安装坚果云客户端（以 Windows 为例）'),
        const _GuideLine('2. 打开客户端，点左下角的「设置」齿轮'),
        const _GuideLine('3. 在设置面板右侧点「第三方应用管理 → 管理」'),
        const _GuideLine('4. 点「添加应用密码」，应用名称填 SyncReader，复制口令'),
        const SizedBox(height: AppSpacing.s2),
        const _CopyableCommand(),
        const SizedBox(height: AppSpacing.s2),
        const _Notice('应用密码与登录密码不同，仅开放文件权限。'),
        const SizedBox(height: AppSpacing.s2),
        // 图文指引默认收起，点「图文指引」按钮展开（避免一进来就是一大串图）。
        TextButton.icon(
          onPressed: () => setState(() => _showImageGuide = !_showImageGuide),
          icon: Icon(
            _showImageGuide ? Icons.expand_less : Icons.help_outline,
            size: 18,
          ),
          label: Text(_showImageGuide ? '收起图文指引' : '图文指引'),
        ),
        if (_showImageGuide) ...[
          const SizedBox(height: AppSpacing.s2),
          const _GuideImageSection(),
        ],
      ],
    );
  }

  // ── 步骤 ②：账号 + 应用密码（含 FR-502 高级项）────────────────────────

  Widget _step2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _accountController,
          decoration: const InputDecoration(
            labelText: '坚果云账号',
            prefixIcon: Icon(Icons.person_outline),
          ),
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s3),
        TextField(
          controller: _passwordController,
          obscureText: true,
          // 应用密码为全小写：防键盘自动首字母大写/联想导致的 401。
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(
            labelText: '应用密码',
            prefixIcon: Icon(Icons.shield_outlined),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s2),
        // FR-502：WebDAV 通用模式（高级项，收起时不占版面）。
        _AdvancedWebDav(
          baseUrl: _baseUrlController,
          rootPath: _rootPathController,
        ),
      ],
    );
  }

  // ── 步骤 ③：自动连接测试 ──────────────────────────────────────────────

  Widget _step3() {
    final result = _result;
    if (result == null) {
      return const Text('检查目录读写与 MOVE 能力');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final step in result.steps)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      step.ok ? Icons.check_circle : Icons.cancel,
                      size: 16,
                      color: step.ok
                          ? Colors.green.shade600
                          : Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    // Expanded：窄窗（480px）下步骤名过长时省略，不横向溢出。
                    Expanded(
                      child: Text(
                        step.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      step.latencyMs == null ? '-' : '${step.latencyMs} ms',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
                // 失败原因/附注（HTTP 状态码、目录不存在等）直接跟进行内。
                if (step.detail != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 22, top: 1),
                    child: Text(
                      step.detail!,
                      style: TextStyle(
                        fontSize: 12,
                        color: step.ok
                            ? Theme.of(context).hintColor
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (!result.success) ...[
          const SizedBox(height: AppSpacing.s2),
          _Notice(result.failureText ?? '连接失败', severe: true),
        ],
      ],
    );
  }

  // ── 步骤 ④：成功页 ────────────────────────────────────────────────────

  Widget _step4() {
    final caps = _result?.capabilities;
    if (caps == null) {
      return const Text('完成连接测试后保存配置。');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.verified, color: Colors.green.shade600, size: 20),
            const SizedBox(width: 6),
            const Expanded(child: Text('连接成功')),
          ],
        ),
        const SizedBox(height: AppSpacing.s2),
        // Expanded：能力文案在窄窗下换行，不横向溢出。
        Row(
          children: [
            Expanded(
              child: Text(
                'MOVE 原子提交：${caps.supportsMove ? '支持' : '不支持（回退校验）'}',
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                'ETag 条件请求：${caps.supportsEtag ? '支持' : '不支持（size+mtime 合成）'}',
              ),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text('Range 断点续传：${caps.supportsRange ? '支持' : '不支持'}'),
            ),
          ],
        ),
      ],
    );
  }
}

// ── 四步进度轨（A12b，对齐原型 .stepper）───────────────────────────────────

/// 步骤轨卡：完成 ✓（brand 浅底）/ 当前（brand 实底 + 光环）/ 未开始（灰），
/// 圆心间连线（走过部分染 brandSoft2）；步骤头部可点（仅已到达步骤）。
class _TrackCard extends StatelessWidget {
  const _TrackCard({
    required this.currentStep,
    required this.maxVisitedStep,
    required this.onStepTapped,
  });

  final int currentStep;
  final int maxVisitedStep;
  final ValueChanged<int> onStepTapped;

  static const _titles = <String>['生成应用密码', '输入账号与应用密码', '自动连接测试', '保存配置'];

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          const gap = AppSpacing.s4;
          final cell = (width - gap * (_kStepCount - 1)) / _kStepCount;
          final half = cell / 2;
          return Stack(
            children: [
              // 圆心连线：从第 1 个圆心到第 4 个圆心（列内圆直径 30、上内边距
              // s1=4，圆心 y = 4 + 15 = 19；2px 线从 18 画到 20 居中对齐）。
              Positioned(
                top: 18,
                left: half,
                right: half,
                child: Container(height: 2, color: t.border),
              ),
              // 已走过部分：到当前步圆心为止染 brandSoft2。
              if (currentStep > 0)
                Positioned(
                  top: 18,
                  left: half,
                  width: currentStep * (cell + gap),
                  child: Container(height: 2, color: t.brandSoft2),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < _kStepCount; i++) ...[
                    if (i > 0) const SizedBox(width: gap),
                    Expanded(
                      child: _TrackStepCell(
                        index: i,
                        title: _titles[i],
                        state: i < currentStep
                            ? _TrackStepState.done
                            : i == currentStep
                            ? _TrackStepState.current
                            : _TrackStepState.pending,
                        enabled: i <= maxVisitedStep && i != currentStep,
                        onTap: () => onStepTapped(i),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个步骤列（圆形序号 + 标题 + 状态说明）。
class _TrackStepCell extends StatelessWidget {
  const _TrackStepCell({
    required this.index,
    required this.title,
    required this.state,
    required this.enabled,
    required this.onTap,
  });

  final int index;
  final String title;
  final _TrackStepState state;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final (desc, descColor) = switch (state) {
      _TrackStepState.done => ('已完成', t.brandText),
      _TrackStepState.current => ('进行中', t.brand),
      _TrackStepState.pending => ('待进行', t.text3),
    };
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
        child: Column(
          children: [
            _circle(t),
            const SizedBox(height: AppSpacing.s2),
            // FittedBox：窄窗下长标题缩放，不横向溢出。
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: state == _TrackStepState.pending ? t.text2 : t.text,
                ),
                maxLines: 1,
              ),
            ),
            const SizedBox(height: 2),
            Text(desc, style: TextStyle(fontSize: 11, color: descColor)),
          ],
        ),
      ),
    );
  }

  /// 圆形序号：完成 = brand 浅底 ✓；当前 = brand 实底 + 光环；未开始 = 灰。
  Widget _circle(AppDesignTokens t) {
    final done = state == _TrackStepState.done;
    final current = state == _TrackStepState.current;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: done
            ? t.brandSoft
            : current
            ? t.brand
            : t.surface3,
        boxShadow: current
            ? [BoxShadow(color: t.brandSoft, blurRadius: 0, spreadRadius: 4)]
            : null,
      ),
      child: done
          ? Icon(Icons.check, size: 14, color: t.brandText)
          : Text(
              '${index + 1}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: current ? Colors.white : t.text3,
              ),
            ),
    );
  }
}

// ── 内容卡与提示构件 ────────────────────────────────────────────────────────

/// 「已保存的配置」快捷卡（向导页顶部，四步进度轨之下）。
///
/// 已有保存配置时出现：显示账号 · 根目录，并提供「使用已保存的配置测试」
/// 次要按钮——不填表直接跑第 3 步的连接测试；结果复用与同步设置页相同的
/// 结果组件（[ConnectionTestResultView]），避免两处样式漂移。
class _SavedConfigCard extends StatelessWidget {
  const _SavedConfigCard({
    required this.account,
    required this.rootPath,
    required this.testing,
    required this.result,
    required this.missing,
    required this.onTest,
    required this.onFill,
  });

  /// 已保存的账号（展示用；不含密码）。
  final String account;

  /// 已保存的同步根目录。
  final String rootPath;

  /// 测试进行中（按钮 loading 态）。
  final bool testing;

  /// 测试结果（null = 还没测过）。
  final ConnectionTestResult? result;

  /// 已保存配置读不到（提示 + 引导回第 2 步填写）。
  final bool missing;

  /// 跑一次「使用已保存的配置测试」。
  final VoidCallback onTest;

  /// 引导回第 2 步（输入账号与应用密码）。
  final VoidCallback onFill;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s5,
        AppSpacing.s4,
        AppSpacing.s5,
        AppSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link, size: 18, color: t.text2),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已保存的配置',
                      style: t.sm.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$account · $rootPath',
                      style: t.tertiary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              TextButton(
                onPressed: testing ? null : onTest,
                child: Text(testing ? '测试中…' : '使用已保存的配置测试'),
              ),
            ],
          ),
          if (missing) ...[
            const SizedBox(height: AppSpacing.s3),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 17, color: t.warn),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(
                    '已保存的配置读取不到，请填写账号与应用密码',
                    style: t.sm.copyWith(color: t.warn),
                  ),
                ),
                TextButton(onPressed: onFill, child: const Text('去填写')),
              ],
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: AppSpacing.s3),
            ConnectionTestResultView(result: result!),
          ],
        ],
      ),
    );
  }
}

/// 当前步内容卡：正文区 + 底部控件区（右对齐，上一步/主按钮）。
class _ContentCard extends StatelessWidget {
  const _ContentCard({
    required this.content,
    required this.controls,
    required this.currentStep,
  });

  final Widget content;
  final Widget controls;
  final int currentStep;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s4,
              AppSpacing.s5,
              AppSpacing.s4,
            ),
            child: content,
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s3,
              AppSpacing.s5,
              AppSpacing.s4,
            ),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: t.border)),
            ),
            child: controls,
          ),
        ],
      ),
    );
  }
}

/// 引导提示条（原型 .notice--warn：应用密码说明等）。
class _Notice extends StatelessWidget {
  const _Notice(this.text, {this.severe = false});

  final String text;

  /// true = danger 语气（连接失败原因），false = warn 语气。
  final bool severe;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final fg = severe ? t.danger : t.warn;
    final bg = severe ? t.dangerSoft : t.warnSoft;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: fg.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            severe ? Icons.error_outline : Icons.info_outline,
            size: 17,
            color: fg,
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(text, style: t.sm.copyWith(color: fg)),
          ),
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
      // Material(transparency)：ExpansionTile 内部 ListTile 在带底色的卡片
      // DecoratedBox 内直接使用会触发"墨水不可见"断言，显式提供 Material 层。
      child: Material(
        type: MaterialType.transparency,
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          title: const Text('高级：自定义 WebDAV 地址/根目录'),
          children: [
            _GuideTextField(controller: baseUrl, label: 'WebDAV 地址'),
            const SizedBox(height: 12),
            _GuideTextField(controller: rootPath, label: '同步根目录'),
          ],
        ),
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

/// 第 1 步的图文指引：桌面客户端生成应用密码的四步截图（点缩略图看大图）。
///
/// 素材由 `assets/jianguoyun/` 提供（JPEG，1080px 宽）；
/// 截图与本文档同源，改图后需同步替换资源并重跑 `flutter build`。
class _GuideImageSection extends StatelessWidget {
  const _GuideImageSection();

  /// 四步指引：(资源路径, 标题, 说明)。
  static const List<(String, String, String)> _steps = [
    (
      'assets/jianguoyun/01-client-download.jpg',
      '下载并安装客户端',
      '官网下载页，下载并安装（以 Windows 为例）',
    ),
    ('assets/jianguoyun/02-client-settings.jpg', '打开设置', '客户端左下角的齿轮图标，点「设置」'),
    (
      'assets/jianguoyun/03-third-party-apps.jpg',
      '第三方应用管理',
      '设置面板右侧「第三方应用管理 → 管理」',
    ),
    (
      'assets/jianguoyun/04-add-app-password.jpg',
      '添加应用密码',
      '应用名称填 SyncReader，生成后复制应用密码',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: t.surface2,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: t.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final step in _steps) ...[
            _GuideImageRow(asset: step.$1, title: step.$2, desc: step.$3),
            if (step != _steps.last) const SizedBox(height: AppSpacing.s2),
          ],
        ],
      ),
    );
  }
}

/// 图文指引的一行：缩略图 + 标题 + 说明（点击缩略图放大预览）。
class _GuideImageRow extends StatelessWidget {
  const _GuideImageRow({
    required this.asset,
    required this.title,
    required this.desc,
  });

  final String asset;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 缩略图：固定比例，点击放大。
        GestureDetector(
          onTap: () => _showPreview(context, asset, title),
          child: Container(
            width: 104,
            height: 62,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: t.border),
            ),
            child: Image.asset(asset, fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: AppSpacing.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.h3),
              const SizedBox(height: 2),
              Text(desc, style: t.caption.copyWith(color: t.text2)),
            ],
          ),
        ),
      ],
    );
  }

  /// 大图预览弹窗。
  Future<void> _showPreview(BuildContext context, String asset, String title) {
    final t = context.appTokens;
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(AppSpacing.s4),
        backgroundColor: t.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s4,
                  AppSpacing.s3,
                  AppSpacing.s2,
                  AppSpacing.s2,
                ),
                child: Row(
                  children: [
                    Expanded(child: Text(title, style: t.h3)),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.s4,
                    0,
                    AppSpacing.s4,
                    AppSpacing.s4,
                  ),
                  child: Image.asset(asset, fit: BoxFit.contain),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
