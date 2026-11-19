/// 自绘分段控件（原型 `ui_prototype/styles.css` 的 `.seg` / `reader.css` 的
/// `.rd-seg`）——**跨页面复用、绝不换行**的分段选择器。
///
/// ## 为什么不用 Material 的 [SegmentedButton]
///
/// M3 分段按钮按「**各段平分**可用宽度」排布，而选中段还要额外塞 18px 的
/// ✓ 勾选图标（+ 8px 间距 + 非对称内边距），合计约 54px 的固定占位。
/// 中文标签本身就宽（「跟随系统」= 4 字 ≈ 52px @13px），两者叠加后：
///
/// - 360px 宽的手机上，4 段（跟随系统/衬线/黑体/楷体）每段只剩 ~72px，
///   扣掉 54px 的固定占位只剩 18px 给标签 → 「跟随/系统」被挤成两行
///   （用户实测「移动端分行，很难看」）；
/// - 控件高度随标签行数忽高忽低，整页版式被带偏。
///
/// 自绘形态同时解决三件事：
/// 1. **不换行**：标签 `maxLines: 1` + 省略号（宁可截断也不分行）；
/// 2. **形态统一**：与阅读页 Aa 面板（v1.3 已改用自绘）同一套观感，
///    与原型 `.seg` 一致（无 ✓、中性底、选中项前景色底 + 轻阴影）；
/// 3. **可预期**：12px 标签 + 8px 内边距，360px 宽下 4 段每段可用 53px，
///    「跟随系统」@12px = 48px，**留有余量**。
library;

import 'package:flutter/material.dart';

/// 自绘分段控件：选项等宽平铺，选中项前景色底 + 600 字重 + 轻阴影。
///
/// 语义：以 [Semantics] 的 `button` + `selected` 暴露选中态（读屏可用），
/// [InkWell] 保留点击/悬停/键盘（Enter/Space）操作能力。
class AppSegmentRow<T> extends StatelessWidget {
  const AppSegmentRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  /// 选项列表：每项为 `(值, 文案)`。
  final List<(T, String)> options;

  /// 当前选中值。
  final T selected;

  /// 选中项变更回调。
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(child: _buildItem(context, options[i])),
          ],
        ],
      ),
    );
  }

  Widget _buildItem(BuildContext context, (T, String) option) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = option.$1 == selected;
    return Semantics(
      button: true,
      selected: isSelected,
      child: Container(
        decoration: isSelected
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                // 选中项：前景色底 + 很轻的阴影（原型 `.seg button.is-on`）。
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              )
            : null,
        child: Material(
          color: isSelected ? scheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => onChanged(option.$1),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                option.$2,
                // **绝不换行**：换行会让控件高度忽高忽低（用户实测「跟随/系统」
                // 分行）。宽度不够时截断并加省略号。
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall!.copyWith(
                  fontSize: 12,
                  height: 1.3,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                  color: isSelected
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
