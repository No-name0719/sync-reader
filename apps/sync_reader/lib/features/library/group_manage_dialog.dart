/// 分组管理对话框（FR-107 本地分类，v1 不参与同步）。
///
/// 新建 / 重命名 / 删除分组，操作即时生效：直接调 `BookGroupsDao`，
/// 列表经 [groupsProvider]（drift watch）自动刷新。重名经 `nameExists`
/// 以 SnackBar 拒绝；删除分组不删书（外键 ON DELETE SET NULL，组内书籍
/// 回到未分组）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/app_database.dart';
import '../../data/db/daos/book_groups_dao.dart';
import 'library_providers.dart';

/// 打开分组管理对话框。
Future<void> showGroupManageDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const GroupManageDialog(),
  );
}

/// 分组管理对话框。
class GroupManageDialog extends ConsumerStatefulWidget {
  const GroupManageDialog({super.key});

  @override
  ConsumerState<GroupManageDialog> createState() => _GroupManageDialogState();
}

class _GroupManageDialogState extends ConsumerState<GroupManageDialog> {
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 取当前面板依赖的 DAO/Messenger（跨 await 前先取，避免悬空引用）。
  (BookGroupsDao, ScaffoldMessengerState) _deps() =>
      (ref.read(bookGroupsDaoProvider), ScaffoldMessenger.of(context));

  /// 新建分组：重名 SnackBar 拒绝；空名由按钮禁用兜底（回车提交也拦截）。
  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    final (dao, messenger) = _deps();
    if (await dao.nameExists(name)) {
      messenger.showSnackBar(SnackBar(content: Text('分组名「$name」已存在')));
      return;
    }
    try {
      await dao.createGroup(name);
      _nameController.clear();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('新建分组失败：$e')));
    }
  }

  /// 重命名分组：改为当前名视为无操作；重名 SnackBar 拒绝。
  Future<void> _rename(BookGroup group) async {
    final newName = await showDialog<String>(
      context: context,
      builder: (_) => _RenameGroupDialog(initial: group.name),
    );
    if (newName == null || !mounted) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == group.name) return;
    final (dao, messenger) = _deps();
    if (await dao.nameExists(trimmed)) {
      messenger.showSnackBar(SnackBar(content: Text('分组名「$trimmed」已存在')));
      return;
    }
    try {
      await dao.renameGroup(group.groupId, trimmed);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('重命名分组失败：$e')));
    }
  }

  /// 删除分组（确认文案说明组内书籍回未分组；外键负责置回，不删书）。
  Future<void> _confirmDelete(BookGroup group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除分组「${group.name}」？'),
        content: const Text('删除分组不会删除书籍，组内书籍将回到未分组。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final (dao, messenger) = _deps();
    try {
      await dao.deleteGroup(group.groupId);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('删除分组失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(groupsProvider).value ?? const <BookGroup>[];
    final canCreate = _nameController.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('管理分组'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameController,
                    // 输入变化 → 刷新"新建"按钮可用态。
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => unawaited(_create()),
                    decoration: const InputDecoration(
                      hintText: '新分组名',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: canCreate ? () => unawaited(_create()) : null,
                  child: const Text('新建'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: groups.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        '暂无分组，先建一个吧',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: groups.length,
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(group.name),
                          trailing: PopupMenuButton<String>(
                            tooltip: '分组操作',
                            onSelected: (value) {
                              if (value == 'rename') unawaited(_rename(group));
                              if (value == 'delete') {
                                unawaited(_confirmDelete(group));
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 重命名对话框：预填旧名；控制器随自身 State 释放（对话框退出动画期间
/// 树仍存活，不能在 pop 返回后立即 dispose）。
class _RenameGroupDialog extends StatefulWidget {
  const _RenameGroupDialog({required this.initial});

  final String initial;

  @override
  State<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends State<_RenameGroupDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名分组'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
