/// 同步设置页（A12 分区重排，FR-405/406/407/409/504/604 + docs/10 §4.5）：
///
/// 从上到下对齐原型（ui_prototype 同步屏，content-inner 820px）：
/// 1. 主卡：后端行（坚果云标识 + 账号 + 连接状态胶囊）→
///    动作行（**「测试连接」**：点一下即测已保存的配置，就地出逐步结果与
///    延迟；「重新配置 / 去配置」走四步向导）→
///    「立即同步」行（右侧主按钮，同步中禁用转圈，FR-406/409）→
///    三条开关行（自动同步 / 仅 Wi-Fi 下载正文 / 配额越权，docs/04 §3/§8.3）；
/// 2. 流量卡：上行/下行双条 + 80% 阈值刻度线 + 超限提示条（FR-407）；
/// 3. 「未上传的书」卡（Q17 新增）：仅本地的书（§4.7c）+ 游离文件（FR-408
///    挂回后上架）两类，逐行「上传到云端」，头部「全部上传」；
/// 4. 「云端书库」卡（新增）：云端书数量 + 进入云端书库管理（/sync/cloudlib）；
/// 5. 维护卡：导出诊断日志（FR-604）；
/// 6. 危险区（红描边卡，与维护区视觉隔离）：清除凭据（FR-504）。
///
/// 「云端孤儿清理」入口按 Q16 决策整行删除（页面文件保留，仅无入口）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sync_core/sync_core.dart';

import '../../../app/providers.dart';
import '../../../core/app_logger.dart';
import '../../../core/design_tokens.dart';
import '../../../core/log_exporter.dart';
import '../../../shared/copy.dart';
import '../../../shared/format_utils.dart';
import '../../../shared/icon_alignment.dart';
import '../../library/orphan/orphan_book_file.dart';
import '../../library/orphan/orphan_panel_controller.dart';
import '../connection_test.dart';
import '../connection_test_result_view.dart';
import '../connection_test_runner.dart';
import '../quota_gate.dart';
import '../sync_facade.dart';
import '../sync_preferences.dart';
import '../sync_status.dart';

// ── 数据源 providers ────────────────────────────────────────────────────────

/// 「未上传的书」行模型：仅本地的书（books 表有正文的书）。
class LocalOnlyBookEntry {
  const LocalOnlyBookEntry({
    required this.bookId,
    required this.title,
    required this.sizeBytes,
  });

  final String bookId;
  final String title;
  final int sizeBytes;
}

/// 仅本地的书清单（drift 流驱动：上传解除标记后行自动消失）。
///
/// 只列 books 表里有正文（localPath 非空）的书——正文已删的书不可上传。
final localOnlyBooksProvider =
    StreamProvider.autoDispose<List<LocalOnlyBookEntry>>((ref) async* {
      final db = ref.watch(databaseProvider);
      await for (final ids in db.localOnlyBooksDao.watchLocalOnlyBookIds()) {
        final entries = <LocalOnlyBookEntry>[];
        for (final bookId in ids) {
          final book = await db.booksDao.getById(bookId);
          if (book == null) continue;
          if ((book.localPath ?? '').isEmpty) continue;
          entries.add(
            LocalOnlyBookEntry(
              bookId: bookId,
              title: book.title,
              sizeBytes: book.sizeBytes,
            ),
          );
        }
        entries.sort((a, b) => a.title.compareTo(b.title));
        yield entries;
      }
    });

/// 云端书数量（云端书库卡；未配置/清单失败 → null → 显示「—」）。
final cloudBookCountProvider = FutureProvider.autoDispose<int?>((ref) {
  return ref.watch(syncFacadeProvider).countCloudBooks();
});

/// 本地书数量（「立即同步」行描述「共 N 本书」）。
final bookCountProvider = StreamProvider.autoDispose<int>((ref) {
  final db = ref.watch(databaseProvider);
  return db.booksDao.watchAllBookIds().map((ids) => ids.length);
});

// ── 上传动作（行按钮与测试共用；真实 IO 由调用方决定运行区）────────────────

/// 「上传到云端」（仅本地的书行）：解除标记 + 清 baseRev + 全量同步上架
/// （docs/10 §4.7c 实施要点 4/6，委托 [SyncFacade.uploadToCloud]）。
Future<bool> uploadLocalOnlyBookToCloud(
  WidgetRef ref,
  LocalOnlyBookEntry entry,
) {
  return ref.read(syncFacadeProvider).uploadToCloud(entry.bookId);
}

/// 游离文件上传结果。
class OrphanUploadOutcome {
  const OrphanUploadOutcome.adopted(this.adoptedTitle)
    : duplicateOf = null,
      failed = false;

  const OrphanUploadOutcome.duplicate(this.duplicateOf)
    : adoptedTitle = null,
      failed = false;

  const OrphanUploadOutcome.failure()
    : adoptedTitle = null,
      duplicateOf = null,
      failed = true;

  /// 挂回成功时的新书标题。
  final String? adoptedTitle;

  /// 库内同内容书的书名（duplicate 分支）。
  final String? duplicateOf;

  final bool failed;

  bool get adopted => adoptedTitle != null;

  bool get isDuplicate => duplicateOf != null;
}

/// 「上传到云端」（游离文件行）：按 contentHash 挂回书库（FR-408 既有
/// `adoptExistingFile` 关联逻辑，经游离面板控制器的防重入包装）→ 挂回成功
/// 触发一次全量同步把新书上架到云端（docs/10 §4.7c 第 2 类）。
///
/// 库内已有同内容书（云端也没有独立可传的正文）→ duplicate（行内灰字
/// 「无法自动上传」）；挂回/同步失败 → failure。
Future<OrphanUploadOutcome> uploadOrphanFileToCloud(
  WidgetRef ref,
  OrphanBookFile orphan,
) async {
  final controller = ref.read(orphanPanelControllerProvider.notifier);
  // OrphanAdoptResult?（游离面板控制器的挂回结果；类型经推断获得，不直接
  // import library/import 侧类型——按禁区约定只依赖 orphan 目录的能力）。
  final result = await () async {
    try {
      return await controller.restore(orphan);
    } catch (_) {
      return null; // 挂回异常折算为失败（UI 提示重试）。
    }
  }();
  if (result == null) return const OrphanUploadOutcome.failure();
  if (result.isDuplicate) {
    return OrphanUploadOutcome.duplicate(result.duplicateOf!);
  }
  // 挂回成功：新书已登记入库，触发全量同步推 meta + 传正文。
  await ref.read(syncFacadeProvider).fullSync(source: SyncTriggerSource.manual);
  return OrphanUploadOutcome.adopted(result.book!.title);
}

// ── 页面 ────────────────────────────────────────────────────────────────────

/// 同步设置页（`/sync/settings`）。
class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(syncConfigProvider);
    final prefs = ref.watch(syncPreferencesProvider);
    final memory = ref.watch(syncMemoryStatusProvider);
    final quotaAsync = ref.watch(quotaSnapshotProvider);
    final lastFullSyncAsync = ref.watch(lastFullSyncAtProvider);
    final localOnlyAsync = ref.watch(localOnlyBooksProvider);
    final cloudCountAsync = ref.watch(cloudBookCountProvider);
    final bookCountAsync = ref.watch(bookCountProvider);

    // 每轮同步结束/开关切换后刷新配额、持久化时间与云端书数量。
    ref.listen(syncMemoryStatusProvider, (_, _) {
      ref.invalidate(quotaSnapshotProvider);
      ref.invalidate(lastFullSyncAtProvider);
      ref.invalidate(cloudBookCountProvider);
    });

    final lastSyncedAt = () {
      final session = memory.lastSyncedAt;
      final persisted = lastFullSyncAsync.value;
      if (session != null && persisted != null) {
        return session.isAfter(persisted) ? session : persisted;
      }
      return session ?? persisted;
    }();

    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      // 居中限宽（原型同步屏 content-inner max-width: 820px）。
      // SingleChildScrollView（非 ListView）：卡片集固定，一次性构建便于
      // 测试直接命中低位卡片，也避免长列表懒加载的滚动定位问题。
      body: SingleChildScrollView(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s6,
                AppSpacing.s6,
                AppSpacing.s6,
                AppSpacing.s12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MainCard(
                    configAsync: configAsync,
                    memory: memory,
                    prefs: prefs,
                    lastSyncedAt: lastSyncedAt,
                    bookCount: bookCountAsync.value,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _QuotaCard(
                    snapshot: quotaAsync.value,
                    statusWarnText: memory.quotaWarnText,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _NotUploadedCard(
                    local: localOnlyAsync.value ?? const [],
                    configured: configAsync.value != null,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  _CloudLibCard(
                    configured: configAsync.value != null,
                    count: cloudCountAsync.value,
                    lastSyncedAt: lastSyncedAt,
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  const _MaintenanceCard(),
                  const SizedBox(height: AppSpacing.s4),
                  const _DangerCard(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 基础构件（卡 / 行 / 胶囊 / 提示条，对齐原型 .card/.row/.pill/.notice）──

/// 原型卡片：surface 底 + 1px 描边 + lg 圆角；可选头部行（标题 + 尾部构件）。
class _Card extends StatelessWidget {
  const _Card({required this.children, this.head, this.danger = false});

  final Widget? head;
  final List<Widget> children;

  /// 危险区样式：描边与头部分隔线染红（原型 color-mix danger 30%/22%）。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final borderColor = danger ? t.danger.withValues(alpha: 0.30) : t.border;
    final headBorderColor = danger
        ? t.danger.withValues(alpha: 0.22)
        : t.border;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (head != null)
            Container(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.s5,
                AppSpacing.s4,
                AppSpacing.s5,
                AppSpacing.s4,
              ),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: headBorderColor)),
              ),
              child: head!,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s5,
              AppSpacing.s4,
              AppSpacing.s5,
              AppSpacing.s4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片头部标题（h3 字阶）。
class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text, {this.danger = false});

  final String text;

  /// 危险区红字（取当前主题令牌 danger）。
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Text(text, style: t.h3.copyWith(color: danger ? t.danger : null));
  }
}

/// 状态胶囊（原型 .pill）：中性/成功/警告/危险/信息 五种语气。
class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.tone = _PillTone.neutral, this.icon});

  final String text;
  final _PillTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final (fg, bg) = switch (tone) {
      _PillTone.neutral => (t.text2, t.surface3),
      _PillTone.ok => (t.success, t.successSoft),
      _PillTone.warn => (t.warn, t.warnSoft),
      _PillTone.danger => (t.danger, t.dangerSoft),
      _PillTone.info => (t.info, t.infoSoft),
    };
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 5),
          ],
          Text(text, style: t.micro.copyWith(fontSize: 11.5, color: fg)),
        ],
      ),
    );
  }
}

enum _PillTone { neutral, ok, warn, danger, info }

/// 列表行（原型 .row）：标题 + 说明 + 尾部构件；行间分隔线由调用方插入。
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.title,
    this.desc,
    this.descColor,
    this.leading,
    this.trailing,
    this.titleColor,
    this.onTap,
  });

  final String title;
  final String? desc;
  final Color? descColor;
  final IconData? leading;
  final Widget? trailing;
  final Color? titleColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final titleStyle = t.sm.copyWith(
      fontWeight: FontWeight.w600,
      color: titleColor ?? t.text,
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.s3),
      child: Row(
        // 顶对齐 + 图标按**标题行盒**居中：此前默认居中对齐会把图标悬在
        // 标题与说明两行之间，看着「图标和字没对齐」。
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leading != null) ...[
            IconLineSlot(
              lineHeight: textLineHeight(titleStyle),
              child: Icon(leading, size: 18, color: titleColor ?? t.text2),
            ),
            const SizedBox(width: AppSpacing.s3),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: titleStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (desc != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    desc!,
                    style: t.tertiary.copyWith(color: descColor ?? t.text3),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.s3),
            trailing!,
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: row,
    );
  }
}

/// 行间分隔线（原型 .row + .row 的 border-top）。
class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: context.appTokens.border);
  }
}

/// 小号按钮（原型 btn--sm）。
class _SmallButton extends StatelessWidget {
  const _SmallButton({
    required this.label,
    required this.onPressed,
    this.outlined = true,
    this.color,
  });

  final String label;
  final VoidCallback? onPressed;

  /// true = 描边钮（btn--outline），false = 软底钮（btn--soft）。
  final bool outlined;

  /// 覆盖描边/文字颜色（危险区红色按钮用）。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final side = BorderSide(color: color ?? t.border);
    final style = outlined
        ? OutlinedButton.styleFrom(
            foregroundColor: color ?? t.text,
            side: side,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
            textStyle: t.sm,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          )
        : FilledButton.styleFrom(
            foregroundColor: color ?? t.brandText,
            backgroundColor: color == null ? t.brandSoft : null,
            minimumSize: const Size(0, 30),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3),
            textStyle: t.sm,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          );
    if (outlined) {
      return OutlinedButton(
        onPressed: onPressed,
        style: style,
        child: Text(label),
      );
    }
    return FilledButton(onPressed: onPressed, style: style, child: Text(label));
  }
}

/// 提示条（原型 .notice）：warn / danger / info 三种语气。
class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.severe});

  final String text;

  /// true = danger 语气（100% 挂起），false = warn 语气（80% 提醒）。
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
          // 图标按**首行文字的行盒**（sm 13×20）居中 → 与文字同一水平中心。
          IconLineSlot(
            lineHeight: textLineHeight(t.sm),
            child: Icon(
              severe ? Icons.error_outline : Icons.warning_amber_rounded,
              size: 17,
              color: fg,
            ),
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

// ── 1. 主卡：后端 / 立即同步 / 开关 ─────────────────────────────────────────

/// 「尚未配置后端」就地提示条（点了「测试连接」但读不到已保存配置时）。
///
/// 不发任何请求（无凭据可测），并给出「去配置」入口回到四步向导。
class _UnconfiguredNotice extends StatelessWidget {
  const _UnconfiguredNotice({required this.onConfigure});

  /// 「去配置」入口（走四步向导）。
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s4,
        vertical: AppSpacing.s3,
      ),
      decoration: BoxDecoration(
        color: t.warnSoft,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: t.warn.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 17, color: t.warn),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text('尚未配置后端', style: t.sm.copyWith(color: t.warn)),
          ),
          TextButton(onPressed: onConfigure, child: const Text('去配置')),
        ],
      ),
    );
  }
}

class _MainCard extends ConsumerStatefulWidget {
  const _MainCard({
    required this.configAsync,
    required this.memory,
    required this.prefs,
    required this.lastSyncedAt,
    required this.bookCount,
  });

  final AsyncValue<SyncConfigSummary?> configAsync;
  final SyncMemoryStatus memory;
  final SyncPreferences prefs;
  final DateTime? lastSyncedAt;
  final int? bookCount;

  @override
  ConsumerState<_MainCard> createState() => _MainCardState();
}

final class _MainCardState extends ConsumerState<_MainCard> {
  /// 「测试连接」进行中（按钮 loading 态；测试期间禁用重复点击）。
  bool _testing = false;

  /// 最近一次连接测试结果（null = 还没测过；重测时整体替换，不叠加）。
  ConnectionTestResult? _testResult;

  /// 未配置提示（已保存配置读不到 → 就地提示，不发请求）。
  bool _unconfigured = false;

  /// 读已保存的后端配置（读不到 → null；不抛异常）。
  Future<BackendConfig?> _readSavedConfig() async {
    try {
      return await ref.read(syncFacadeProvider).readConfig();
    } catch (_) {
      return null;
    }
  }

  /// 跑一次连接测试：**只测不改**——不写凭据、不清凭据、不动同步状态。
  ///
  /// 流程：读已保存配置 → null 则就地提示「尚未配置后端」并不发请求；
  /// 否则经 [connectionTestRunnerProvider] 跑全套测试并就地展示结果。
  Future<void> _runConnectionTest() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _unconfigured = false;
    });
    final config = await _readSavedConfig();
    if (config == null) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _unconfigured = true;
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
      _testing = false;
      _testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.configAsync.value;
    final configured = config != null;
    final memory = widget.memory;
    final prefs = widget.prefs;
    final t = context.appTokens;

    // 连接状态胶囊：未配置 / 失败 / 已连接（FR-405/406）。
    final (pillText, pillTone, pillIcon) = !configured
        ? ('未配置', _PillTone.neutral, Icons.cloud_off_outlined)
        : memory.id == SyncStateId.failed
        ? ('失败', _PillTone.danger, Icons.cloud_off_outlined)
        : ('已连接', _PillTone.ok, Icons.check);

    final syncing = memory.id == SyncStateId.syncing;
    final accountLine = configured
        ? '${config.account} · ${config.rootPath}'
        : '未配置坚果云账号（引导式配置）';

    return _Card(
      children: [
        // ── 后端行（FR-405）──
        Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [t.info, Color.alphaBlend(Colors.black26, t.info)],
                ),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Text(
                '坚',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.s4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '坚果云 WebDAV',
                    style: t.h3,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    accountLine,
                    style: t.tertiary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.s3),
            _Pill(pillText, tone: pillTone, icon: pillIcon),
          ],
        ),
        const SizedBox(height: AppSpacing.s3),

        // ── 后端动作行：「测试连接」（主色，点击即测已保存配置）
        //    +「重新配置 / 去配置」（文字/描边钮，走四步向导）──
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FilledButton.icon(
              onPressed: _testing ? null : _runConnectionTest,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 16),
              label: Text(_testing ? '测试中' : '测试连接'),
            ),
            const SizedBox(width: AppSpacing.s2),
            if (configured)
              TextButton(
                onPressed: () => context.push('/sync/guide'),
                child: const Text('重新配置'),
              )
            else
              _SmallButton(
                label: '去配置',
                onPressed: () => context.push('/sync/guide'),
              ),
          ],
        ),

        // ── 测试结果（就地展示于后端卡内；重测时整体替换）──
        if (_unconfigured) ...[
          const SizedBox(height: AppSpacing.s3),
          _UnconfiguredNotice(onConfigure: () => context.push('/sync/guide')),
        ],
        if (_testResult != null) ...[
          const SizedBox(height: AppSpacing.s3),
          ConnectionTestResultView(result: _testResult!),
        ],
        const _RowDivider(),

        // ── 「立即同步」独立行（FR-409）──
        _SettingsRow(
          title: '手动同步',
          desc: _syncDesc(),
          descColor: memory.id == SyncStateId.failed ? t.text3 : null,
          trailing: FilledButton.icon(
            onPressed: syncing
                ? null
                : () => ref
                      .read(syncFacadeProvider)
                      .fullSync(source: SyncTriggerSource.manual),
            icon: syncing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync, size: 18),
            label: const Text('立即同步'),
          ),
        ),
        if (memory.failureText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s2),
            child: Text(
              '失败原因：${memory.failureText}',
              style: t.caption.copyWith(color: t.danger),
            ),
          ),
        const _RowDivider(),

        // ── 开关行（标题 + 说明 + 开关；docs/04 §3）──
        // Material(transparency)：ListTile 在带底色 DecoratedBox（卡片）内
        // 直接使用会触发“墨水不可见”断言，这里显式提供 Material 层。
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '自动同步',
              style: t.sm.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text('定时与网络恢复时自动触发', style: t.tertiary),
            value: prefs.autoSyncEnabled,
            onChanged: (value) => ref
                .read(syncPreferencesProvider.notifier)
                .setAutoSyncEnabled(value),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '仅 Wi-Fi 下载正文',
              style: t.sm.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text('正文下载避开移动网络', style: t.tertiary),
            value: prefs.wifiOnlyContent,
            onChanged: (value) => ref
                .read(syncPreferencesProvider.notifier)
                .setWifiOnlyContent(value),
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            key: const ValueKey('sync-quota-override-switch'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              '配额越权',
              style: t.sm.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              prefs.quotaOverride
                  ? '本月正文下载将继续'
                  : '流量超限后放行，继续下载正文',
              style: t.tertiary,
            ),
            value: prefs.quotaOverride,
            onChanged: (value) async {
              if (!value) {
                await ref
                    .read(syncPreferencesProvider.notifier)
                    .setQuotaOverride(false);
                return;
              }
              // 越权需明确二次确认（docs/04 §8.3）。
              final messenger = ScaffoldMessenger.of(context);
              final confirmed = await _confirmOverride(context);
              if (confirmed) {
                await ref
                    .read(syncPreferencesProvider.notifier)
                    .setQuotaOverride(true);
              } else {
                messenger.hideCurrentSnackBar();
              }
            },
          ),
        ),
      ],
    );
  }

  /// 「立即同步」行说明：状态 + 上次同步时间 + 本地书数（FR-406）。
  String _syncDesc() {
    final memory = widget.memory;
    final lastSyncedAt = widget.lastSyncedAt;
    final bookCount = widget.bookCount;
    final countText = bookCount == null ? '' : ' · 共 $bookCount 本书';
    return switch (memory.id) {
      SyncStateId.unconfigured => '云端同步未配置',
      SyncStateId.syncing => '正在同步…',
      SyncStateId.idle =>
        lastSyncedAt == null
            ? '同步空闲'
            : '上次同步：${formatEpochMs(lastSyncedAt.millisecondsSinceEpoch)}$countText',
      SyncStateId.ok =>
        '上次同步：${formatEpochMs(lastSyncedAt!.millisecondsSinceEpoch)}$countText',
      SyncStateId.failed => '上次同步失败',
    };
  }

  /// 越权放行二次确认弹窗（docs/04 §8.3）。
  Future<bool> _confirmOverride(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本月流量已达上限'),
        content: const Text(
          '继续下载将占用坚果云超额流量，'
          '可能产生额外费用或被服务方限制。确定继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('继续下载'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }
}

// ── 2. 流量卡（FR-407）──────────────────────────────────────────────────────

class _QuotaCard extends ConsumerWidget {
  const _QuotaCard({required this.snapshot, this.statusWarnText});

  final QuotaSnapshot? snapshot;

  /// 内存侧告警文案（同步过程中实时上报；快照未告警时兜底展示）。
  final String? statusWarnText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    final snap = snapshot;
    if (snap == null) {
      return _Card(
        head: const _CardTitle('本月流量'),
        children: [Text('配额信息不可用（未配置后端）', style: t.tertiary)],
      );
    }
    final upRatio = snap.upRatio.clamp(0.0, 1.0);
    final downRatio = snap.downRatio.clamp(0.0, 1.0);
    final maxRatio = upRatio > downRatio ? upRatio : downRatio;

    // 提示条优先级：100% 挂起 > 80% 提醒 > 内存侧实时告警兜底（docs/04 §8.3）。
    final String? bannerText;
    if (snap.downExceeded) {
      bannerText = '正文传输已全部挂起，可在「配额越权」开关继续（将消耗坚果云额度）';
    } else if (snap.warn) {
      bannerText = '本月同步流量已超过 80%，自动下载已暂停；元数据同步不受影响。正文仍可手动继续下载。';
    } else {
      bannerText = statusWarnText;
    }

    return _Card(
      head: Row(
        children: [
          const _CardTitle('本月流量'),
          const SizedBox(width: AppSpacing.s2),
          Text(snap.month ?? '-', style: t.tertiary),
          const Spacer(),
          _Pill(
            '已用 ${(maxRatio * 100).round()}%',
            tone: maxRatio >= QuotaLimits.warnRatio
                ? _PillTone.warn
                : _PillTone.neutral,
          ),
        ],
      ),
      children: [
        _QuotaBar(label: '上行（书库元数据 + 正文）', used: snap.upBytes, ratio: upRatio),
        const SizedBox(height: AppSpacing.s4),
        _QuotaBar(
          label: '下行（云端正文下载）',
          used: snap.downBytes,
          ratio: downRatio,
          showMark: true,
        ),
        if (bannerText != null) ...[
          const SizedBox(height: AppSpacing.s4),
          _Notice(bannerText, severe: snap.downExceeded),
        ],
      ],
    );
  }
}

/// 单行配额条（原型 .quota-row）：标签 + 用量 · 百分比 + 进度条；
/// [showMark] 时叠加 80% 阈值刻度线（原型 .quota-track .mark）。
class _QuotaBar extends StatelessWidget {
  const _QuotaBar({
    required this.label,
    required this.used,
    required this.ratio,
    this.showMark = false,
  });

  final String label;
  final int used;
  final double ratio;
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final over = ratio >= QuotaLimits.warnRatio;
    final barColor = over ? t.warn : t.brand;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                label,
                style: t.tertiary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.s2),
            Text(
              '${humanizeBytes(used)} · ${(ratio * 100).round()}%',
              style: t.caption.copyWith(
                color: t.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Stack（clip none）承载进度条与溢出画出的 80% 刻度线。
        SizedBox(
          height: 6,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    height: 6,
                    decoration: BoxDecoration(
                      color: t.surface3,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: ratio,
                        child: Container(
                          decoration: BoxDecoration(
                            color: barColor,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (showMark)
                    Positioned(
                      left: width * QuotaLimits.warnRatio - 1,
                      top: -5,
                      bottom: -5,
                      width: 2,
                      child: Container(color: t.warn.withValues(alpha: 0.8)),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── 3. 「未上传的书」卡（Q17）───────────────────────────────────────────────

class _NotUploadedCard extends ConsumerStatefulWidget {
  const _NotUploadedCard({required this.local, required this.configured});

  final List<LocalOnlyBookEntry> local;
  final bool configured;

  @override
  ConsumerState<_NotUploadedCard> createState() => _NotUploadedCardState();
}

final class _NotUploadedCardState extends ConsumerState<_NotUploadedCard> {
  /// 上传中的仅本地 bookId（行内转圈，防重复点击）。
  final Set<String> _busyBookIds = {};

  /// 上传中的游离文件 path。
  final Set<String> _busyOrphans = {};

  /// 「全部上传」进行中（冻结全部行按钮）。
  bool _uploadingAll = false;

  /// 游离行的行内灰字说明（如「无法自动上传」duplicate 提示）。
  final Map<String, String> _orphanNotes = {};

  bool get _busy =>
      _uploadingAll || _busyBookIds.isNotEmpty || _busyOrphans.isNotEmpty;

  Future<void> _uploadEntry(LocalOnlyBookEntry entry) async {
    if (_busy) return;
    setState(() => _busyBookIds.add(entry.bookId));
    final messenger = ScaffoldMessenger.of(context);
    final ok = await uploadLocalOnlyBookToCloud(ref, entry);
    if (!mounted) return;
    setState(() => _busyBookIds.remove(entry.bookId));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? '《${entry.title}》已上传到云端' : '《${entry.title}》上传失败，请检查网络或稍后重试',
        ),
      ),
    );
  }

  Future<void> _uploadOrphan(OrphanBookFile orphan) async {
    if (_busy) return;
    setState(() => _busyOrphans.add(orphan.path));
    final messenger = ScaffoldMessenger.of(context);
    final outcome = await uploadOrphanFileToCloud(ref, orphan);
    if (!mounted) return;
    setState(() {
      _busyOrphans.remove(orphan.path);
      if (outcome.isDuplicate) {
        _orphanNotes[orphan.path] = '无法自动上传：库内已有同内容书《${outcome.duplicateOf}》';
      }
    });
    if (outcome.adopted) {
      messenger.showSnackBar(
        SnackBar(content: Text('《${outcome.adoptedTitle}》已挂回书库并上传到云端')),
      );
    } else if (outcome.failed) {
      messenger.showSnackBar(const SnackBar(content: Text('上传失败，请检查网络或稍后重试')));
    }
  }

  /// 「全部上传」：逐本上传两类条目，完成后汇总提示。
  Future<void> _uploadAll() async {
    if (_busy) return;
    final orphans = ref.read(orphanPanelControllerProvider).orphans;
    if (widget.local.isEmpty && orphans.isEmpty) return;
    setState(() => _uploadingAll = true);
    final messenger = ScaffoldMessenger.of(context);
    var ok = 0;
    var fail = 0;
    for (final entry in widget.local) {
      final done = await uploadLocalOnlyBookToCloud(ref, entry);
      if (!mounted) return;
      done ? ok++ : fail++;
    }
    for (final orphan in orphans) {
      final outcome = await uploadOrphanFileToCloud(ref, orphan);
      if (!mounted) return;
      outcome.adopted ? ok++ : fail++;
    }
    if (!mounted) return;
    setState(() => _uploadingAll = false);
    messenger.showSnackBar(
      SnackBar(content: Text('全部上传完成：成功 $ok 本，失败 $fail 本')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    // watch 保活 autoDispose 控制器：清单/扫描态由此提供，books 表变化
    // （挂回入库等）自动重扫（orphan_panel_controller 的既有职责）。
    final orphanState = ref.watch(orphanPanelControllerProvider);
    final orphans = orphanState.orphans;
    final total = widget.local.length + orphans.length;
    return _Card(
      head: Row(
        children: [
          const _CardTitle('未上传的书'),
          const Spacer(),
          if (total > 0) ...[
            _Pill('$total 本', tone: _PillTone.warn),
            const SizedBox(width: AppSpacing.s2),
          ],
          _SmallButton(
            label: '全部上传',
            outlined: false,
            onPressed: _busy || total == 0 ? null : _uploadAll,
          ),
        ],
      ),
      children: [
        if (total == 0) ...[
          const SizedBox(height: AppSpacing.s3),
          widget.configured
              ? Row(
                  children: [
                    Icon(Icons.check_circle, size: 18, color: t.success),
                    const SizedBox(width: AppSpacing.s2),
                    Text('全部已同步', style: t.sm.copyWith(color: t.success)),
                  ],
                )
              : Text('配置同步后，这里会列出本地有、云端没有的书', style: t.tertiary),
        ],
        if (widget.local.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s3),
          _groupCaption('仅本地的书'),
          for (final (index, entry) in widget.local.indexed) ...[
            if (index > 0) const _RowDivider(),
            _SettingsRow(
              leading: Icons.menu_book_outlined,
              title: entry.title,
              desc: '${humanizeBytes(entry.sizeBytes)} · 仅本地',
              trailing: _busyBookIds.contains(entry.bookId) || _uploadingAll
                  ? const _RowSpinner()
                  : _SmallButton(
                      label: '上传到云端',
                      onPressed: () => _uploadEntry(entry),
                    ),
            ),
          ],
        ],
        if (orphans.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s3),
          _groupCaption('游离文件'),
          for (final (index, orphan) in orphans.indexed) ...[
            if (index > 0) const _RowDivider(),
            _SettingsRow(
              leading: Icons.description_outlined,
              title: orphan.fileName,
              desc:
                  _orphanNotes[orphan.path] ??
                  '${humanizeBytes(orphan.sizeBytes)} · ${orphan.shapeLabel} · ${orphan.formatLabel}',
              trailing: _orphanNotes.containsKey(orphan.path)
                  ? null
                  : _busyOrphans.contains(orphan.path) || _uploadingAll
                  ? const _RowSpinner()
                  : _SmallButton(
                      label: '上传到云端',
                      onPressed: () => _uploadOrphan(orphan),
                    ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _groupCaption(String text) {
    final t = context.appTokens;
    return Text(text, style: t.micro.copyWith(color: t.text2));
  }
}

/// 行内上传中指示（小号转圈）。
class _RowSpinner extends StatelessWidget {
  const _RowSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

// ── 4. 云端书库卡 ───────────────────────────────────────────────────────────

class _CloudLibCard extends StatelessWidget {
  const _CloudLibCard({
    required this.configured,
    required this.count,
    required this.lastSyncedAt,
  });

  final bool configured;

  /// 云端书数量（null = 未配置或计数失败）。
  final int? count;
  final DateTime? lastSyncedAt;

  @override
  Widget build(BuildContext context) {
    final t = context.appTokens;
    final desc = !configured
        ? '配置同步后可管理云端书籍'
        : count == null
        ? '— 本'
        : lastSyncedAt == null
        ? '$count 本'
        : '$count 本 · 上次同步 ${formatEpochMs(lastSyncedAt!.millisecondsSinceEpoch)}';
    return _Card(
      head: const _CardTitle('云端书库'),
      children: [
        InkWell(
          key: const ValueKey('cloudlib-entry'),
          onTap: () => context.go('/sync/cloudlib'),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
            child: Row(
              children: [
                Icon(Icons.cloud_outlined, size: 20, color: t.brand),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '管理云端书籍',
                        style: t.sm.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(desc, style: t.tertiary),
                    ],
                  ),
                ),
                Text('进入管理', style: t.tertiary),
                Icon(Icons.chevron_right, size: 16, color: t.text3),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        Text('含其它设备上传的书', style: t.tertiary),
      ],
    );
  }
}

// ── 5. 维护卡 ───────────────────────────────────────────────────────────────

class _MaintenanceCard extends ConsumerWidget {
  const _MaintenanceCard();

  static final _log = AppLogger();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _Card(
      head: const _CardTitle('维护'),
      children: [
        // 注：v1.1 起「测试连接」唯一化在后端卡（点一下即测**已保存**的配置，
        // 就地显示逐步结果与延迟）。此处原有一个同名入口（点击跳转向导），
        // 功能重复且行为不一致——正是用户反馈的「要走一遍流程」，故移除。
        // 导出诊断日志（FR-604）：行点击导出；旁附「清空日志」。
        _SettingsRow(
          leading: Icons.article_outlined,
          title: '导出诊断日志',
          desc: '另存为 txt 文件',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => _confirmClearLogs(context),
                child: const Text('清空日志'),
              ),
              _SmallButton(
                label: '导出',
                onPressed: () => _exportLogs(context, ref),
              ),
            ],
          ),
          onTap: () => _exportLogs(context, ref),
        ),
      ],
    );
  }

  /// 导出诊断日志（FR-604）：
  /// 组装（二次脱敏）→ file_picker 另存对话框（v13 的 saveFile 自带写盘，
  /// 内容以 bytes 传入）→ SnackBar 反馈路径与行数；用户取消静默返回。
  Future<void> _exportLogs(BuildContext context, WidgetRef ref) async {
    // 在异步间隙前取好 messenger 与 saver，避免 context/ref 跨 await 使用。
    final messenger = ScaffoldMessenger.of(context);
    final saver = ref.read(logFileSaverProvider);
    try {
      final bundle = await LogExporter.buildContent();
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp =
          '${now.year}${two(now.month)}${two(now.day)}'
          '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final uri = await saver.save(
        fileName: 'syncreader-log-$stamp.txt',
        bytes: utf8.encode(bundle.content),
      );
      if (uri == null) return; // 用户取消，静默返回。
      messenger.showSnackBar(
        SnackBar(
          content: Text('已导出 ${bundle.lineCount} 行日志到 ${_displayPath(uri)}'),
        ),
      );
    } catch (e) {
      _log.error('导出诊断日志失败', e);
      messenger.showSnackBar(const SnackBar(content: Text('导出失败，请稍后重试')));
    }
  }

  /// 展示用路径：file scheme 转本机路径，其余（如 Android content://）原样。
  static String _displayPath(Uri uri) =>
      uri.scheme == 'file' ? uri.toFilePath() : uri.toString();

  /// 清空日志：确认对话框 → [AppLogger.clear]（仅清内存缓冲，不动书库）。
  Future<void> _confirmClearLogs(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text(
          '将清空诊断日志，'
          '书库、阅读进度与云端数据不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      AppLogger.clear();
    }
  }
}

// ── 6. 危险区（红描边卡）────────────────────────────────────────────────────

class _DangerCard extends ConsumerWidget {
  const _DangerCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.appTokens;
    return _Card(
      danger: true,
      head: const _CardTitle('危险操作', danger: true),
      children: [
        _SettingsRow(
          leading: Icons.key_off,
          title: '清除凭据',
          titleColor: t.danger,
          desc: '删除账号、应用密码与设备关联信息',
          trailing: _SmallButton(
            label: '清除',
            onPressed: () => _confirmClearCredentials(context, ref),
            color: t.danger,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmClearCredentials(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除凭据？'),
        content: const Text(
          '将删除账号与应用密码，'
          '本地书库与阅读进度不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(syncFacadeProvider).clearCredentials();
    }
  }
}

// ── 日志保存器（既有能力，保留）────────────────────────────────────────────

/// 日志保存器抽象：把 file_picker v13 静态 API 挡在接口后面，测试可注入假实现。
abstract interface class LogFileSaver {
  /// 弹出另存对话框并写入 [bytes]；用户取消返回 null。
  Future<Uri?> save({required String fileName, required Uint8List bytes});
}

/// 默认实现：file_picker v13 静态 API（saveFile 选择路径后自行写盘）。
final class FilePickerLogFileSaver implements LogFileSaver {
  const FilePickerLogFileSaver();

  @override
  Future<Uri?> save({required String fileName, required Uint8List bytes}) {
    return FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: 'text/plain',
    );
  }
}

/// 日志保存器提供者（设置页导出入口使用）。
final logFileSaverProvider = Provider<LogFileSaver>(
  (ref) => const FilePickerLogFileSaver(),
);
