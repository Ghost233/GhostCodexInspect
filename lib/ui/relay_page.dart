/// 中转台页面（工单 #13）：WS server 状态、token 展示与一键复制带
/// token URL、已连接远程端列表、「允许局域网访问」开关、中继会话控制。
library;

import 'package:flutter/material.dart';

import '../dom/dom.dart';
import '../screencast/screencast.dart';
import '../video/video.dart';
import 'home_shell.dart';
import 'host_controller.dart';
import 'theme.dart';
import 'widgets.dart';

class RelayPage extends StatelessWidget {
  const RelayPage({super.key, required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final status = controller.relayStatus;
        final running = status.running;
        return PageScaffold(
          title: '中转台',
          actions: [
            if (controller.busy) BusyBar(action: '${controller.busyAction}中…'),
          ],
          children: [
            if (controller.lastError != null)
              ErrorBar(message: controller.lastError!),
            _ServerCard(controller: controller, running: running),
            if (running) ...[
              _AccessCard(controller: controller),
              _SessionCard(controller: controller),
              _ClientsCard(controller: controller),
            ] else
              SectionCard(
                title: '远程访问入口',
                child: Text(
                  '中转未运行。启动后这里会给出带 token 的访问地址、'
                  '中继会话控制与远程端列表。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            _SecurityNoteCard(allowLanAccess: controller.allowLanAccess),
          ].whereType<Widget>().toList(),
        );
      },
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({required this.controller, required this.running});

  final HostController controller;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final status = controller.relayStatus;
    return SectionCard(
      title: 'WebSocket 服务',
      trailing: StatusChip(
        label: running ? '运行中' : '已停止',
        tone: running ? StatusTone.success : StatusTone.neutral,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldRow(
            label: '监听地址',
            value: status.running ? '${status.address}:${status.port}' : '—',
            mono: true,
          ),
          FieldRow(
            label: '允许局域网访问',
            value: controller.allowLanAccess ? '开（绑 LAN IP）' : '关（仅 127.0.0.1）',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.icon(
                onPressed: controller.busy || running
                    ? null
                    : controller.startRelay,
                icon: const Icon(Icons.play_arrow, size: 16),
                label: const Text('启动中转'),
              ),
              OutlinedButton.icon(
                onPressed: controller.busy || !running
                    ? null
                    : controller.stopRelay,
                icon: const Icon(Icons.stop_outlined, size: 16),
                label: const Text('停止中转'),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: controller.allowLanAccess,
                    onChanged: controller.busy
                        ? null
                        : (v) => controller.setLanAccess(v ?? false),
                  ),
                  GestureDetector(
                    onTap: controller.busy
                        ? null
                        : () => controller.setLanAccess(
                            !controller.allowLanAccess,
                          ),
                    child: const Text('允许局域网访问'),
                  ),
                ],
              ),
            ],
          ),
          if (controller.allowLanAccess) ...[
            const SizedBox(height: 8),
            Text(
              '局域网开关打开后，任何拿到 token 的 LAN 设备都能接管目标应用'
              '（CDP ≈ 任意代码执行）。仅在受信网络开启。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: statusToneColor(context, StatusTone.warning),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final url = controller.accessUrl;
    final token = controller.launcher.relay.token;
    return SectionCard(
      title: '远程访问入口',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldRow(label: '访问地址', value: url?.toString() ?? '—', mono: true),
          FieldRow(label: '令牌', value: token ?? '—', mono: true),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              if (url != null)
                CopyButton(text: url.toString(), label: '复制带 token URL'),
              if (token != null) CopyButton(text: token, label: '复制 token'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '令牌每次启动中转重新生成；停止中转即全部远程端失效。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final kind = controller.sessionKind;
    final status = controller.sessionStatus;
    final busy = controller.busy;
    return SectionCard(
      title: '中继会话',
      trailing: StatusChip(
        label: kind.label,
        tone: kind == SessionKind.none
            ? StatusTone.neutral
            : StatusTone.success,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FieldRow(
            label: 'CDP 实现',
            value: controller.cdpImplementationName ?? '—',
            mono: true,
          ),
          if (status is DomSessionStatus) ...[
            FieldRow(label: '事件批次', value: '${status.batchesReceived}'),
            FieldRow(label: '下发信封', value: '${status.envelopesSent}'),
            FieldRow(label: '输入事件', value: '${status.inputsDispatched}'),
            FieldRow(label: '最近错误', value: status.lastError ?? '无'),
          ] else if (status is ScreencastSessionStatus) ...[
            FieldRow(label: '已发帧', value: '${status.framesSent}'),
            FieldRow(label: '输入事件', value: '${status.inputsDispatched}'),
            FieldRow(
              label: '最近一帧',
              value: status.lastFrameAt == null
                  ? '—'
                  : DateTime.fromMillisecondsSinceEpoch(status.lastFrameAt!)
                        .toIso8601String(),
              mono: true,
            ),
            FieldRow(label: '最近错误', value: status.lastError ?? '无'),
          ] else if (status is VideoSessionStatus) ...[
            FieldRow(label: '编码器', value: status.encoder ?? '—', mono: true),
            FieldRow(label: '已编码帧', value: '${status.framesEncoded}'),
            FieldRow(label: '已发 AU', value: '${status.ausSent}'),
            FieldRow(
              label: '视频字节',
              value: '${(status.bytesSent / 1024).toStringAsFixed(1)} KB',
            ),
            FieldRow(label: '最近错误', value: status.lastError ?? '无'),
          ],
          const SizedBox(height: 8),
          Text(
            '一期互斥约定：同时只允许一个中继会话；切换模式即停旧起新，'
            '远程端会自动 resync。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: busy || kind == SessionKind.dom
                    ? null
                    : () => controller.startSession(SessionKind.dom),
                icon: const Icon(Icons.web_outlined, size: 16),
                label: const Text('DOM 重绘模式'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy || kind == SessionKind.screencast
                    ? null
                    : () => controller.startSession(SessionKind.screencast),
                icon: const Icon(Icons.screenshot_monitor_outlined, size: 16),
                label: const Text('画面流模式'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy || kind == SessionKind.video
                    ? null
                    : () => controller.startSession(SessionKind.video),
                icon: const Icon(Icons.videocam_outlined, size: 16),
                label: const Text('视频流模式'),
              ),
              OutlinedButton.icon(
                onPressed: busy || kind == SessionKind.none
                    ? null
                    : controller.stopSession,
                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                label: const Text('停止会话'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ClientsCard extends StatelessWidget {
  const _ClientsCard({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final clients = controller.relayClients;
    return SectionCard(
      title: '远程端',
      trailing: StatusChip(label: '${clients.length} 已连接'),
      child: clients.isEmpty
          ? Text(
              '尚无远程端连接。远程端通过访问地址（含 token）接入后列在这里。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          : Column(
              children: [
                for (final client in clients)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        StatusDot(
                          tone: client.authed
                              ? StatusTone.success
                              : StatusTone.warning,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: MonoText('client #${client.id}')),
                        StatusChip(
                          label: client.authed ? '已鉴权' : '待鉴权',
                          tone: client.authed
                              ? StatusTone.success
                              : StatusTone.warning,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SecurityNoteCard extends StatelessWidget {
  const _SecurityNoteCard({required this.allowLanAccess});

  final bool allowLanAccess;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '安全边界',
      child: Text(
        'CDP 端口等于目标应用的任意代码执行权，token 泄漏 ≈ 整机沦陷。\n'
        '默认仅绑 127.0.0.1；跨机访问必须走 SSH 隧道 / Tailscale，'
        '不要裸暴露端口。${allowLanAccess ? '当前已开启局域网访问，请确认网络可信。' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}
