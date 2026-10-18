/// 检查器页面（工单 #13）：CDP 连接健康、shell 页面枚举、加固检测结果。
///
/// 探测是对目标应用 CDP 端口的只读勘察：连接 → 枚举页面 → 读标题 →
/// 断开，不改页面状态、不碰输入（注入脚本存活探测走 Runtime.evaluate
/// 轮询）。
library;

import 'package:flutter/material.dart';

import '../inspector/inspector.dart';
import 'home_shell.dart';
import 'host_controller.dart';
import 'launcher_page.dart';
import 'theme.dart';
import 'widgets.dart';

class InspectorPage extends StatelessWidget {
  const InspectorPage({super.key, required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final report = controller.probeReport;
        return PageScaffold(
          title: '检查器',
          actions: [
            if (controller.busy) BusyBar(action: '${controller.busyAction}中…'),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: controller.busy ? null : controller.runProbe,
              icon: const Icon(Icons.network_check, size: 16),
              label: const Text('CDP 探测'),
            ),
          ],
          children: [
            if (controller.lastError != null)
              ErrorBar(message: controller.lastError!),
            PreflightChecksCard(report: controller.preflight),
            if (report == null)
              SectionCard(
                title: 'CDP 探测',
                child: Text(
                  '尚未探测。前提：目标应用带调试端口（默认 9238）运行。'
                  '探测是只读勘察，不改页面状态。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else ...[
              _ConnectionCard(report: report, controller: controller),
              _ShellTargetCard(report: report),
            ],
          ].whereType<Widget>().toList(),
        );
      },
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.report, required this.controller});

  final InspectorReport report;
  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final conn = report.connection;
    return SectionCard(
      title: 'CDP 连接',
      trailing: StatusChip(
        label: report.healthy ? '健康' : '异常',
        tone: report.healthy ? StatusTone.success : StatusTone.error,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (conn != null) ...[
            FieldRow(
              label: 'CDP 实现',
              value: conn.implementationName,
              mono: true,
            ),
            FieldRow(
              label: '降级回退',
              value: conn.fellBack
                  ? '是（puppeteer 失败：${conn.puppeteerError ?? '未知原因'}）'
                  : '否',
            ),
          ],
          if (report.error != null)
            FieldRow(label: '失败原因', value: '${report.error}'),
          if (conn == null && report.error == null)
            Text('连接信息缺失。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ShellTargetCard extends StatelessWidget {
  const _ShellTargetCard({required this.report});

  final InspectorReport report;

  @override
  Widget build(BuildContext context) {
    final target = report.shellTarget;
    final hardening = report.preflight.inspection.signature.hardenedRuntime;
    return SectionCard(
      title: 'shell 页面',
      trailing: StatusChip(
        label: target == null ? '未发现' : '已找到',
        tone: target == null ? StatusTone.warning : StatusTone.success,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (target != null) ...[
            FieldRow(label: 'URL', value: target.url, mono: true),
            FieldRow(label: '类型', value: target.type, mono: true),
            FieldRow(label: 'Target ID', value: target.id, mono: true),
            FieldRow(label: '页面标题', value: report.shellTitle ?? '读取失败'),
          ] else
            Text(
              '未发现匹配页面 scheme 前缀的 shell target。'
              '目标应用若已更新，URL scheme 可能漂移。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('注入脚本存活探测：'),
              const SizedBox(width: 8),
              StatusChip(
                label: hardening ? '待 #4 实测（加固应用）' : '待 #4 实测',
                tone: StatusTone.neutral,
              ),
            ],
          ),
          if (hardening) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('加固检测：'),
                const SizedBox(width: 8),
                const StatusChip(
                  label: 'hardened runtime',
                  tone: StatusTone.warning,
                ),
                const SizedBox(width: 8),
                const StatusChip(
                  label: 'ElectronAsarIntegrity',
                  tone: StatusTone.warning,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '加固应用可能拦截 --remote-debugging-port 或校验 asar 完整性；'
              'asar 重打包路线已被 #2 排除，启动参数路线不受影响。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
