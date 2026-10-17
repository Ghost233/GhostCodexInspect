/// 宿主 UI 公共组件（工单 #13）：状态标记、区域卡片、等宽文本、字段行。
///
/// 尺寸约定见 macos-ui-standards 基线：区域卡片圆角 12、内边距 24；
/// 状态 chip 圆角 6；等宽用于 token / 路径 / 端口等标识。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// 语义状态 chip：颜色 + 文字（不单靠颜色传达状态）。
class StatusChip extends StatelessWidget {
  const StatusChip({super.key, required this.label, this.tone = StatusTone.neutral});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = statusToneColor(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? .12 : .08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// 状态圆点（用于侧栏/行内紧凑状态）。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.tone = StatusTone.neutral, this.size = 8});

  final StatusTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: statusToneColor(context, tone),
      ),
    );
  }
}

/// 区域卡片：区域标题（Title 3 角色）+ 内容。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              ?trailing,
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// 等宽文本（token、路径、pid、端口等标识）；可选中复制。
class MonoText extends StatelessWidget {
  const MonoText(this.data, {super.key, this.style});

  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      data,
      style: (style ?? Theme.of(context).textTheme.bodySmall)?.copyWith(
        fontFamily: 'Menlo',
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

/// 标签—值字段行（标签 120 宽，辅助文字角色）。
class FieldRow extends StatelessWidget {
  const FieldRow({super.key, required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: mono
                ? MonoText(value)
                : SelectableText(
                    value,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
          ),
        ],
      ),
    );
  }
}

/// 复制按钮：复制 [text] 到剪贴板并 snackbar 确认。
class CopyButton extends StatelessWidget {
  const CopyButton({super.key, required this.text, required this.label, this.tooltip});

  final String text;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '复制$label',
      child: TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            ScaffoldMessenger.of(context)
              ..clearSnackBars()
              ..showSnackBar(SnackBar(content: Text('已复制$label')));
          }
        },
        icon: const Icon(Icons.copy_outlined, size: 16),
        label: Text(label),
      ),
    );
  }
}
