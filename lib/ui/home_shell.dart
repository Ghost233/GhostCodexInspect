/// 主窗口外壳（工单 #13）：macOS 侧栏导航 + 四模块页面切换。
///
/// 侧栏约定（macos-ui-standards 基线）：宽 224，浅层分组，选中行用强调色
/// 背景；窗口标题用 Title 2 角色。底部固定 MacLauncher 连接状态。
library;

import 'package:flutter/material.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'host_controller.dart';
import 'inspector_page.dart';
import 'launcher_page.dart';
import 'preview_page.dart';
import 'relay_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 主外壳：侧栏 + 当前模块页。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final HostController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.rocket_launch_outlined, label: '启动器'),
    (icon: Icons.fact_check_outlined, label: '检查器'),
    (icon: Icons.hub_outlined, label: '中转台'),
    (icon: Icons.monitor_outlined, label: '远程视图'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pages = [
      LauncherPage(controller: widget.controller),
      InspectorPage(controller: widget.controller),
      RelayPage(controller: widget.controller),
      PreviewPage(controller: widget.controller),
    ];
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 224,
            color: scheme.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
                  child: Text(
                    'GhostCodexInspect',
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _destinations.length,
                    itemBuilder: (context, i) {
                      final dest = _destinations[i];
                      final selected = i == _index;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: _SidebarItem(
                          icon: dest.icon,
                          label: dest.label,
                          selected: selected,
                          onTap: () => setState(() => _index = i),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                _LauncherStatusFooter(controller: widget.controller),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: IndexedStack(index: _index, children: pages),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = widget.selected
        ? scheme.primary.withValues(alpha: dark ? .22 : .14)
        : _hovered
        ? scheme.onSurface.withValues(alpha: .05)
        : null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 16,
                color: widget.selected
                    ? scheme.primary
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 侧栏底部：MacLauncher 连接状态（SDK 状态流）。
class _LauncherStatusFooter extends StatelessWidget {
  const _LauncherStatusFooter({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final status = controller.sdkStatus;
    final (tone, text) = switch (status?.state) {
      SdkConnectionState.connected => (StatusTone.success, 'MacLauncher 已连接'),
      SdkConnectionState.connecting => (StatusTone.warning, 'MacLauncher 连接中…'),
      SdkConnectionState.rejected => (StatusTone.warning, 'MacLauncher 待批准或拒绝'),
      SdkConnectionState.disconnected ||
      null => (StatusTone.neutral, 'MacLauncher 未连接'),
    };
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          StatusDot(tone: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 页面脚手架：主标题（Title 1 角色）+ 工具动作 → 分隔线 → 内容。
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.children,
    this.actions = const [],
  });

  final String title;
  final List<Widget> actions;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Row(
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              ...actions,
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 24),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 操作进行中提示条（就地忙碌状态，防重复提交由按钮禁用负责）。
class BusyBar extends StatelessWidget {
  const BusyBar({super.key, required this.action});

  final String action;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(action, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// 就地错误提示条（失败状态：简短原因 + 保留上下文）。
class ErrorBar extends StatelessWidget {
  const ErrorBar({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final color = statusToneColor(context, StatusTone.error);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: .35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
