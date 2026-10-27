/// pdf 阅读视图的纯 Flutter 组件：主题背景色映射、悬浮页码指示、页码跳转
/// 对话框。有意**不依赖 pdfrx**——widget 测试无需触发 PdfDocument 加载
/// （flutter test 环境无 pdfium.dll）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../contract/reader_settings.dart';
import 'pdf_locator.dart';

/// ReaderTheme → pdf 画布背景色（页面外的留白区）。
Color pdfViewerBackgroundColor(ReaderTheme theme) => switch (theme) {
  ReaderTheme.light => const Color(0xFF9E9E9E), // pdfrx 默认灰
  ReaderTheme.dark => const Color(0xFF1A1A1A),
  ReaderTheme.paper => const Color(0xFFE8E2D0),
};

/// 悬浮页码指示：`当前页 / 总页数`（1 起展示），点击弹出页码跳转对话框。
class PdfPageIndicator extends StatelessWidget {
  const PdfPageIndicator({
    super.key,
    required this.pageIndexListenable,
    required this.pageCount,
    required this.onTap,
  });

  /// 当前页（0 起）的监听源。
  final ValueListenable<int> pageIndexListenable;

  /// 总页数（未知/退化时 <= 0，显示 `–`）。
  final int pageCount;

  /// 点击指示器（宿主弹跳转对话框）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface.withValues(alpha: 0.92),
      elevation: 2,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: ValueListenableBuilder<int>(
            valueListenable: pageIndexListenable,
            builder: (context, pageIndex, _) => Text(
              pageCount > 0 ? '${pageIndex + 1} / $pageCount' : '–',
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: colors.onSurface),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹出页码跳转对话框；确认且输入有效时以 **0 起页码** 回调 [onJump]。
///
/// 取消/空白收起返回 null；输入非法时表单校验拦截（FR-205 页码跳转）。
Future<void> showPdfPageJumpDialog(
  BuildContext context, {
  required int pageCount,
  required ValueChanged<int> onJump,
}) async {
  int? parsed;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final formKey = GlobalKey<FormState>();
      final input = TextEditingController();
      return AlertDialog(
        title: const Text('跳转到页'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '页码（1–$pageCount）',
              hintText: pageCount > 0 ? '1' : null,
            ),
            validator: (value) => parsePageInput(value ?? '', pageCount) == null
                ? '请输入 1–$pageCount 之间的整数页码'
                : null,
            onFieldSubmitted: (_) => _submit(
              dialogContext,
              formKey,
              input,
              pageCount,
              (v) => parsed = v,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => _submit(
              dialogContext,
              formKey,
              input,
              pageCount,
              (v) => parsed = v,
            ),
            child: const Text('跳转'),
          ),
        ],
      );
    },
  );
  final index = parsed;
  if (index != null) onJump(index);
}

/// 校验并在通过时关闭对话框（0 起页码经 [out] 传出）。
void _submit(
  BuildContext dialogContext,
  GlobalKey<FormState> formKey,
  TextEditingController input,
  int pageCount,
  ValueChanged<int> out,
) {
  if (!(formKey.currentState?.validate() ?? false)) return;
  final index = parsePageInput(input.text, pageCount);
  if (index == null) return;
  out(index);
  Navigator.of(dialogContext).pop();
}
