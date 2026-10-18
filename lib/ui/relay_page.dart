/// 中转台页面（工单 #13）：WS server 状态、token 展示与一键复制带
/// token URL、已连接远程端列表、「允许局域网访问」开关、中继会话控制。
library;

import 'package:flutter/material.dart';

import '../dom/dom.dart';
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
              _VideoCapsCard(controller: controller),
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
          _RelayPortEditor(controller: controller, running: running),
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
          // 视频流编码参数（#25）：启动视频会话时生效
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _VideoSettingDropdown<VideoCodecKind>(
                label: '编码格式',
                value: controller.videoCodec,
                items: const [
                  (VideoCodecKind.h264, 'H.264'),
                  (VideoCodecKind.hevc, 'H.265'),
                  (VideoCodecKind.av1, 'AV1'),
                ],
                onChanged: (v) => controller.setVideoCodec(v),
              ),
              _VideoSettingDropdown<VideoEncoderKind>(
                label: '编码器',
                value: controller.videoEncoderKind,
                items: const [
                  (VideoEncoderKind.auto, '自动（硬编优先）'),
                  (VideoEncoderKind.hardware, '强制硬编'),
                  (VideoEncoderKind.software, '强制软编'),
                ],
                onChanged: (v) => controller.setVideoEncoderKind(v),
              ),
              _VideoSettingDropdown<int?>(
                label: '分辨率上限',
                value: controller.videoMaxWidth,
                items: const [
                  (null, '原始'),
                  (1600, '1600'),
                  (1280, '1280'),
                  (960, '960'),
                  (640, '640'),
                ],
                onChanged: (v) => controller.setVideoMaxWidth(v),
              ),
              _VideoSettingDropdown<int?>(
                label: '码率',
                value: controller.videoBitrateKbps,
                items: const [
                  (null, '自动'),
                  (4000, '4 Mbps'),
                  (2000, '2 Mbps'),
                  (1000, '1 Mbps'),
                  (500, '500 kbps'),
                ],
                onChanged: (v) => controller.setVideoBitrateKbps(v),
              ),
            ],
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

/// 视频设置下拉（#25）：label + 紧凑 DropdownButton。
class _VideoSettingDropdown<T> extends StatelessWidget {
  const _VideoSettingDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 6),
        DropdownButton<T>(
          value: value,
          isDense: true,
          underline: const SizedBox.shrink(),
          items: [
            for (final (v, text) in items)
              DropdownMenuItem<T>(value: v, child: Text(text)),
          ],
          onChanged: (v) => onChanged(v as T),
        ),
      ],
    );
  }
}

/// 编码能力矩阵（#25）：ffmpeg 各编码器可用性（编译级探测）。
class _VideoCapsCard extends StatelessWidget {
  const _VideoCapsCard({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final caps = controller.encoderCapabilities;
    final ffmpegPath = controller.ffmpegPath;
    return SectionCard(
      title: '编码能力（宿主）',
      trailing: StatusChip(
        label: ffmpegPath != null ? 'ffmpeg 就绪' : '未找到 ffmpeg',
        tone: ffmpegPath != null ? StatusTone.success : StatusTone.warning,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (ffmpegPath == null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    '未找到 ffmpeg，视频流模式不可用。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: statusToneColor(context, StatusTone.warning),
                    ),
                  ),
                ),
                // 去沙盒后内置安装（#25）：brew install ffmpeg 带进度
                FilledButton(
                  onPressed: controller.ffmpegInstalling
                      ? null
                      : () => controller.installFfmpeg(),
                  child: const Text('一键安装'),
                ),
                const SizedBox(width: 8),
                CopyButton(
                  text: 'brew install ffmpeg',
                  label: '安装命令',
                ),
              ],
            ),
            if (controller.ffmpegInstalling) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: controller.ffmpegInstallPercent != null
                    ? controller.ffmpegInstallPercent! / 100
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                controller.ffmpegInstallLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ]
          else ...[
            for (final cap in caps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(
                        cap.codec.toUpperCase(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        cap.hardware ? '硬编' : '软编',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(child: MonoText(cap.name)),
                    StatusChip(
                      label: cap.available ? '可用' : '缺失',
                      tone: cap.available
                          ? StatusTone.success
                          : StatusTone.error,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Text(
              '硬编实际可用性以会话启动时的运行时探测为准（失败自动回退软编）。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: controller.busy
                ? null
                : controller.refreshVideoCapabilities,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新探测'),
          ),
        ],
      ),
    );
  }
}

/// 中转端口编辑行（#26）：0=随机（默认），固定端口供多实例并存。
/// 中转运行中修改会在下次启动中转时生效。
class _RelayPortEditor extends StatefulWidget {
  const _RelayPortEditor({required this.controller, required this.running});

  final HostController controller;
  final bool running;

  @override
  State<_RelayPortEditor> createState() => _RelayPortEditorState();
}

class _RelayPortEditorState extends State<_RelayPortEditor> {
  late final TextEditingController _text =
      TextEditingController(text: '${widget.controller.relayPort}');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final port = int.tryParse(_text.text.trim());
    if (port == null || (port != 0 && (port < 1024 || port > 65535))) {
      setState(() => _error = '0（随机）或 1024-65535');
      return;
    }
    await widget.controller.setRelayPort(port);
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text('远程访问端口', style: theme.textTheme.bodyMedium),
        ),
        SizedBox(
          width: 96,
          child: TextField(
            controller: _text,
            enabled: !widget.running,
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
        TextButton(
          onPressed: widget.running ? null : _apply,
          child: const Text('应用'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.running ? '运行中不可改；停止中转后可修改' : '0 = 随机端口',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
