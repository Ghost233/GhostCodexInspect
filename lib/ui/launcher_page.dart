/// 启动器页面（工单 #13）：目标检测状态、前提校验结果、带参启动/停止/
/// 重启（真实目标应用操作前弹确认对话框）。
///
/// 术语遵循 GLOSSARY.md：本模块叫「启动器」，是工具内模块；
/// MacLauncher 是独立产品（侧栏底部状态）。
library;

import 'package:flutter/material.dart';

import '../launcher/launcher.dart';
import 'home_shell.dart';
import 'host_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class LauncherPage extends StatelessWidget {
  const LauncherPage({super.key, required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return PageScaffold(
          title: '启动器',
          actions: [
            if (controller.busy) BusyBar(action: '${controller.busyAction}中…'),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: controller.busy ? null : controller.refreshTarget,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新检测'),
            ),
          ],
          children: [
            if (controller.lastError != null)
              ErrorBar(message: controller.lastError!),
            _TargetCard(controller: controller),
            PreflightChecksCard(report: controller.preflight),
            _RunStateCard(controller: controller),
          ].whereType<Widget>().toList(),
        );
      },
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final profile = controller.profile;
    final report = controller.preflight;
    final inspection = report?.inspection;
    final detected = inspection?.bundleExists == true;
    return SectionCard(
      title: '目标应用',
      trailing: StatusChip(
        label: detected ? '已检测到' : (report == null ? '未检测' : '未找到'),
        tone: detected
            ? StatusTone.success
            : (report == null ? StatusTone.neutral : StatusTone.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldRow(label: '名称', value: profile.displayName),
          FieldRow(label: '路径', value: profile.appPath, mono: true),
          FieldRow(label: 'Bundle ID', value: profile.bundleId, mono: true),
          if (inspection != null) ...[
            FieldRow(
              label: '版本',
              value:
                  '${inspection.version ?? '未知'}（build ${inspection.buildNumber ?? '未知'}）',
            ),
            FieldRow(
              label: 'Electron 框架',
              value: inspection.frameworkPath ?? '未发现',
              mono: true,
            ),
            FieldRow(
              label: '签名',
              value: inspection.signature.checked
                  ? '${inspection.signature.authority ?? '未知签名'}'
                        '${inspection.signature.hardenedRuntime ? '，hardened runtime' : ''}'
                  : '未校验',
            ),
            if (inspection.signature.hardenedRuntime)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    StatusChip(
                      label: '加固：hardened runtime',
                      tone: StatusTone.warning,
                    ),
                    SizedBox(width: 8),
                    StatusChip(
                      label: 'ElectronAsarIntegrity',
                      tone: StatusTone.warning,
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 前提校验结果列表（启动器与检查器共用）。
class PreflightChecksCard extends StatelessWidget {
  const PreflightChecksCard({super.key, required this.report});

  final PreflightReport? report;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '前提校验',
      trailing: report == null
          ? const StatusChip(label: '未执行')
          : StatusChip(
              label: report!.passed ? '通过' : '未通过',
              tone: report!.passed ? StatusTone.success : StatusTone.error,
            ),
      child: report == null
          ? Text(
              '尚未检测目标应用。在「启动器」页点「重新检测」执行前提校验。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : Column(
              children: [
                for (final check in report!.checks) _CheckRow(check: check),
              ],
            ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.check});

  final PreflightCheck check;

  @override
  Widget build(BuildContext context) {
    final (icon, tone) = check.passed
        ? (Icons.check_circle_outline, StatusTone.success)
        : check.fatal
        ? (Icons.error_outline, StatusTone.error)
        : (Icons.warning_amber_outlined, StatusTone.warning);
    final color = statusToneColor(context, tone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          SizedBox(
            width: 180,
            child: Text(
              check.name,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'Menlo', fontSize: 12),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              check.detail,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _RunStateCard extends StatelessWidget {
  const _RunStateCard({required this.controller});

  final HostController controller;

  Future<void> _confirmAndRun(
    BuildContext context, {
    required String actionLabel,
    required String warning,
    required Future<void> Function({required bool confirmed}) run,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.warning_amber_outlined),
        title: Text('$actionLabel目标应用'),
        content: SizedBox(
          width: 480,
          child: Text(
            '目标应用是真实应用 ${controller.profile.displayName}。\n'
            '$warning\n\n'
            '注意：本机 codex CLI 正在支撑其他项目开发，本操作不会触碰 CLI，'
            '但会中断目标应用内的现有会话窗口。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(actionLabel),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await run(confirmed: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = controller.targetRunning;
    final busy = controller.busy;
    return SectionCard(
      title: '运行状态',
      trailing: StatusChip(
        label: running ? '运行中' : '未运行',
        tone: running ? StatusTone.success : StatusTone.neutral,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (running)
            FieldRow(
              label: '进程 PID',
              value: controller.runningPids.join(', '),
              mono: true,
            ),
          _DebugPortEditor(controller: controller),
          const SizedBox(height: 8),
          Text(
            '带参启动会先完全退出运行中的实例，再以调试端口拉起'
            '（open -a 对已运行实例会丢弃参数）。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => _confirmAndRun(
                        context,
                        actionLabel: '带参启动',
                        warning: '启动会先完全退出当前实例，再带调试端口拉起。',
                        run: controller.launchTarget,
                      ),
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('带参启动'),
              ),
              OutlinedButton.icon(
                onPressed: busy || !running
                    ? null
                    : () => _confirmAndRun(
                        context,
                        actionLabel: '重启',
                        warning: '重启会先完全退出当前实例，再以相同调试端口拉起。',
                        run: controller.restartTarget,
                      ),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('重启'),
              ),
              OutlinedButton.icon(
                onPressed: busy || !running
                    ? null
                    : () => _confirmAndRun(
                        context,
                        actionLabel: '停止',
                        warning: '停止会向目标应用发送退出信号（SIGTERM，超时 SIGKILL）。',
                        run: controller.stopTarget,
                      ),
                icon: Icon(
                  Icons.stop_outlined,
                  size: 16,
                  color: statusToneColor(context, StatusTone.error),
                ),
                label: Text(
                  '停止',
                  style: TextStyle(
                    color: statusToneColor(context, StatusTone.error),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 调试端口编辑行（#26）：可修改并持久化，供多实例并存时避开端口冲突。
class _DebugPortEditor extends StatefulWidget {
  const _DebugPortEditor({required this.controller});

  final HostController controller;

  @override
  State<_DebugPortEditor> createState() => _DebugPortEditorState();
}

class _DebugPortEditorState extends State<_DebugPortEditor> {
  late final TextEditingController _text =
      TextEditingController(text: '${widget.controller.debugPort}');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final port = int.tryParse(_text.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = '端口须是 1024-65535 的整数');
      return;
    }
    await widget.controller.setDebugPort(port);
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text('调试端口', style: theme.textTheme.bodyMedium),
        ),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _text,
            keyboardType: TextInputType.number,
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              isDense: true,
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _apply(),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: _apply, child: const Text('应用')),
      ],
    );
  }
}
