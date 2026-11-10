/// 中转台页面（工单 #13）：WS server 状态、访问地址列表、token 展示、
/// 密钥设置、「允许远程访问」开关、中继会话控制。
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
            _AccessCard(controller: controller),
            _SessionCard(controller: controller, running: running),
            if (running) ...[
              _VideoCapsCard(controller: controller),
              _ClientsCard(controller: controller),
            ],
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
            label: '允许远程访问',
            value: controller.allowLanAccess ? '开（0.0.0.0）' : '关（仅 127.0.0.1）',
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
                    child: const Text('允许远程访问'),
                  ),
                ],
              ),
            ],
          ),
          if (controller.allowLanAccess) ...[
            const SizedBox(height: 8),
            Text(
              '已监听所有 IPv4 接口。远程端须通过访问密钥与 token 校验，'
              '请妥善保管两项凭据。',
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
    final urls = controller.accessUrls;
    final token = controller.relayToken;
    return SectionCard(
      title: '远程访问入口',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (urls.isEmpty)
            const FieldRow(label: '访问地址', value: '—', mono: true)
          else
            for (var i = 0; i < urls.length; i++)
              FieldRow(
                label: i == 0 ? '访问地址' : '',
                value: urls[i].toString(),
                mono: true,
              ),
          FieldRow(label: '令牌', value: token ?? '—', mono: true),
          _AccessKeyEditor(controller: controller),
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('固定 token（手动轮转）'),
              value: controller.useFixedRelayToken,
              onChanged: controller.busy
                  ? null
                  : (value) => controller.setFixedRelayToken(value ?? false),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: controller.busy || token == null
                ? null
                : controller.rotateRelayToken,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('立即轮转 token'),
          ),
          const SizedBox(height: 8),
          Text(
            controller.useFixedRelayToken
                ? '固定 token 已保存，重启后保持不变。轮转会断开全部远程端，并要求重新验证密钥。'
                : 'token 每次启动中转重新生成；勾选固定后保存当前 token。远程页面须先输入访问密钥。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.controller, required this.running});

  final HostController controller;
  final bool running;

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
            FieldRow(
              label: '编码状态',
              value: status.encoding ? '编码中' : '已暂停（无观众）',
            ),
            FieldRow(label: '观看数', value: '${status.viewers}'),
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
          if (!running)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '视频流参数（启动视频会话时生效）。启动会话需先启动中转。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
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
              _BitrateSlider(controller: controller),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: busy || !running || kind == SessionKind.dom
                    ? null
                    : () => controller.startSession(SessionKind.dom),
                icon: const Icon(Icons.web_outlined, size: 16),
                label: const Text('DOM 重绘模式'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy || !running || kind == SessionKind.video
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
        'CDP 连接具备控制目标应用的权限，请妥善保管访问密钥和 token。\n'
        '默认监听 127.0.0.1，开启远程访问后监听 0.0.0.0。'
        '${allowLanAccess ? '跨网络传输建议使用 HTTPS 代理或加密隧道。' : ''}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _AccessKeyEditor extends StatefulWidget {
  const _AccessKeyEditor({required this.controller});

  final HostController controller;

  @override
  State<_AccessKeyEditor> createState() => _AccessKeyEditorState();
}

class _AccessKeyEditorState extends State<_AccessKeyEditor> {
  final _text = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_text.text.trim().length < 8) {
      setState(() => _error = '访问密钥至少 8 个字符');
      return;
    }
    await widget.controller.setRelayAccessKey(_text.text);
    if (!mounted) return;
    if (widget.controller.lastError == null) {
      _text.clear();
      setState(() => _error = null);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            obscureText: true,
            enabled: !widget.controller.busy,
            decoration: InputDecoration(
              labelText: '访问密钥',
              hintText: widget.controller.hasRelayAccessKey
                  ? '已设置，输入新密钥可重设'
                  : '输入至少 8 个字符',
              helperText: widget.controller.hasRelayAccessKey
                  ? '密钥不提供查看或复制，遗失后请重新设置。'
                  : '首次使用请先设置访问密钥。',
              errorText: _error,
              isDense: true,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          onPressed: widget.controller.busy ? null : _save,
          child: const Text('保存密钥'),
        ),
      ],
    ),
  );
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

/// 码率滑条（#27）：1–50 Mbps，拖动结束才持久化。
class _BitrateSlider extends StatelessWidget {
  const _BitrateSlider({required this.controller});

  final HostController controller;

  @override
  Widget build(BuildContext context) {
    final kbps = controller.videoBitrateKbps;
    final mbps = kbps / 1000;
    final label = mbps >= 10
        ? '${mbps.toStringAsFixed(0)} Mbps'
        : '${mbps.toStringAsFixed(1)} Mbps';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('码率', style: Theme.of(context).textTheme.bodySmall),
        SizedBox(
          width: 220,
          child: Slider(
            value: kbps.toDouble(),
            min: 1000,
            max: 50000,
            divisions: 49,
            label: label,
            onChanged: (v) => controller.previewVideoBitrateKbps(v.round()),
            onChangeEnd: (v) => controller.setVideoBitrateKbps(v.round()),
          ),
        ),
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
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
                CopyButton(text: 'brew install ffmpeg', label: '安装命令'),
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
          ] else ...[
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
  late final TextEditingController _text = TextEditingController(
    text: '${widget.controller.relayPort}',
  );
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
