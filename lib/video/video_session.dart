/// 视频流会话（工单 #22/#25）：CDP screencast JPEG 帧 → ffmpeg 编码 →
/// video 通道 AU 下发（h264/hevc Annex B；av1 IVF 拆帧 OBU）。
/// 与 DOM 会话互斥（共享中转回调）。
///
/// 晚到客户端：立即补发 videoMeta，画面从下一个关键帧 AU 开始可解码
/// （GOP 48 @ 30fps 名义值，最长等待约 1.6s；远程端在拿到关键帧前
/// 丢弃 delta AU）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/dom/input_dispatcher.dart';
import 'package:ghost_codex_inspect/relay/envelope.dart';
import 'package:ghost_codex_inspect/relay/relay_server.dart';
import 'package:ghost_codex_inspect/video/ffmpeg_locator.dart';
import 'package:ghost_codex_inspect/video/video_encoder.dart';

/// 视频流会话状态（中转台/检查器展示用）。
class VideoSessionStatus {
  const VideoSessionStatus({
    required this.active,
    required this.encoder,
    required this.framesEncoded,
    required this.ausSent,
    required this.idrAusSent,
    required this.bytesSent,
    this.lastError,
  });

  final bool active;

  /// 实际生效的编码器（'h264_videotoolbox' / 'libx264'；未启动为 null）。
  final String? encoder;
  final int framesEncoded;
  final int ausSent;

  /// 其中含 IDR 的 AU 数（关键帧节奏诊断）。
  final int idrAusSent;
  final int bytesSent;
  final String? lastError;
}

/// 视频流会话。
class VideoSession {
  VideoSession({
    required this.page,
    required this.relay,
    this.codec = VideoCodecKind.h264,
    this.encoderKind = VideoEncoderKind.auto,
    this.bitrateKbps,
    this.quality = 60,
    this.everyNthFrame = 2,
    this.maxWidth = 1280,
    this.onSwitchRequested,
    this.locator = const FfmpegLocator(),
  });

  final CdpPage page;
  final RelayServer relay;
  final VideoCodecKind codec;
  final VideoEncoderKind encoderKind;

  /// 码率（kbps；null = 编码器自动）。
  final int? bitrateKbps;
  final int quality;
  final int everyNthFrame;
  final int? maxWidth;

  /// #16：远程端请求切换 shell 页面时回调（宿主重建会话）。
  final void Function(String targetId)? onSwitchRequested;

  /// ffmpeg 定位器（可注入 fake 便于测试）。
  final FfmpegLocator locator;

  FfmpegVideoEncoder? _encoder;
  StreamSubscription<ScreencastFrameData>? _frameSub;
  StreamSubscription<Uint8List>? _auSub;
  bool _active = false;
  int _framesEncoded = 0;
  int _ausSent = 0;
  int _idrAusSent = 0;
  int _bytesSent = 0;
  String? _lastError;
  final _firstAu = Completer<void>();

  bool get isActive => _active;

  /// 首个 AU 编码完成（E2E 等待点）。
  Future<void> get firstAccessUnit => _firstAu.future;

  VideoSessionStatus get status => VideoSessionStatus(
    active: _active,
    encoder: _encoder?.activeEncoder,
    framesEncoded: _framesEncoded,
    ausSent: _ausSent,
    idrAusSent: _idrAusSent,
    bytesSent: _bytesSent,
    lastError: _lastError,
  );

  /// 启动：互斥守卫 → ffmpeg 探测与编码器启动 → Page.enable →
  /// videoMeta → startScreencast → 帧喂编码器 → AU 广播。
  Future<void> start() async {
    if (_active) return;
    // 一期互斥约定：与 DOM/画面流会话共享中转回调（#12 决策）
    if (relay.onClientMessage != null || relay.onClientAuthed != null) {
      throw StateError('中转消息回调已被另一会话占用（一期互斥约定：先 stop 另一个会话）');
    }
    final lookup = await locator.find();
    if (!lookup.available) {
      throw StateError('未找到 ffmpeg：请先 ${FfmpegLocator.installCommand}');
    }
    final encoder = FfmpegVideoEncoder(
      ffmpegPath: lookup.path!,
      codec: codec,
      kind: encoderKind,
      bitrateKbps: bitrateKbps,
    );
    await encoder.start();
    _encoder = encoder;

    relay.onClientMessage = _handleClientMessage;
    relay.onClientAuthed = _handleClientAuthed;

    await page.send('Page.enable');
    await _broadcastVideoMeta();
    await page.send('Page.startScreencast', {
      'format': 'jpeg',
      'quality': quality,
      'everyNthFrame': everyNthFrame,
      if (maxWidth != null) 'maxWidth': maxWidth,
    });

    _frameSub = page.screencastFrames.listen(
      _onFrame,
      onError: (Object e) => _lastError = '$e',
    );
    _auSub = encoder.accessUnits.listen(
      _onAccessUnit,
      onError: (Object e) => _lastError = '$e',
    );
    _active = true;
  }

  Future<void> _broadcastVideoMeta() async {
    final raw = await page.evaluate(
      'JSON.stringify({viewportWidth: innerWidth, viewportHeight: innerHeight})',
    );
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    relay.broadcast(RelayChannel.video, RelayMessageType.videoMeta, {
      'codec': codec.wireTag,
      'encoder': _encoder?.activeEncoder ?? 'unknown',
      'viewportWidth': map['viewportWidth'],
      'viewportHeight': map['viewportHeight'],
    });
  }

  void _onFrame(ScreencastFrameData frame) {
    // ack 必须在下一帧到来前返回（CDP 流控）
    unawaited(
      page
          .send('Page.screencastFrameAck', {'sessionId': frame.sessionId})
          .catchError((_) => <String, dynamic>{}),
    );
    _encoder?.writeFrame(base64Decode(frame.data));
    _framesEncoded++;
  }

  void _onAccessUnit(Uint8List au) {
    _ausSent++;
    if (_isKeyframeAu(au)) _idrAusSent++;
    _bytesSent += au.length;
    if (!_firstAu.isCompleted) _firstAu.complete();
    relay.broadcast(
      RelayChannel.video,
      RelayMessageType.videoFrame,
      base64Encode(au), // v1 客户端文本回退
      binaryPayload: au, // v2 客户端二进制帧
    );
  }

  /// AU 是否为关键帧（关键帧节奏诊断）：
  /// h264=含 IDR slice（type 5）；hevc=含 IDR_N_LP(20)/IDR_W_RADL(19)；
  /// av1=含序列头 OBU（type 1，svt-av1 每个 GOP 重发）。
  bool _isKeyframeAu(Uint8List au) {
    switch (codec) {
      case VideoCodecKind.av1:
        return _containsObuType(au, 1);
      case VideoCodecKind.h264:
      case VideoCodecKind.hevc:
        for (var i = 0; i + 4 < au.length; i++) {
          if (au[i] == 0 &&
              au[i + 1] == 0 &&
              (au[i + 2] == 1 || (au[i + 2] == 0 && au[i + 3] == 1))) {
            final hi = au[i + 2] == 1 ? i + 3 : i + 4;
            if (hi >= au.length) continue;
            if (codec == VideoCodecKind.h264) {
              if ((au[hi] & 0x1f) == 5) return true;
            } else {
              final t = (au[hi] >> 1) & 0x3f;
              if (t == 19 || t == 20) return true;
            }
          }
        }
        return false;
    }
  }

  /// av1 AU（低开销 OBU 载荷）内是否含指定 OBU 类型。
  static bool _containsObuType(Uint8List au, int type) {
    var i = 0;
    while (i + 1 < au.length) {
      final header = au[i];
      final obuType = (header >> 3) & 0x0f;
      final hasSize = (header & 0x02) != 0;
      final hasExt = (header & 0x04) != 0;
      var j = i + 1 + (hasExt ? 1 : 0);
      if (obuType == type) return true;
      if (!hasSize) break; // 无长度字段：整个剩余即该 OBU
      // leb128 长度
      var size = 0;
      var shift = 0;
      while (j < au.length) {
        final b = au[j++];
        size |= (b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
      }
      i = j + size;
    }
    return false;
  }

  void _handleClientAuthed(int clientId) {
    // 晚到补种：videoMeta 立即发；画面从下一个关键帧起可解码（远程端
    // 在拿到关键帧前丢 delta AU）。
    unawaited(_broadcastVideoMeta());
  }

  void _handleClientMessage(int clientId, RelayEnvelope envelope) {
    if (envelope.channel == RelayChannel.ctrl &&
        envelope.type == RelayMessageType.switchTarget) {
      final data = envelope.data;
      if (data is Map) {
        final targetId = data['targetId'];
        if (targetId is String && targetId.isNotEmpty) {
          onSwitchRequested?.call(targetId);
        }
      }
      return;
    }
    if (envelope.channel != RelayChannel.input ||
        envelope.type != RelayMessageType.input) {
      return;
    }
    final data = envelope.data;
    if (data is! Map) return;
    unawaited(
      dispatchInput(
        page,
        data.cast<String, dynamic>(),
      ).catchError((Object e) => _lastError = '$e'),
    );
  }

  /// 停止（幂等）：停 screencast + 编码器，归还中转回调。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _frameSub?.cancel();
    _frameSub = null;
    await _auSub?.cancel();
    _auSub = null;
    try {
      await page.send('Page.stopScreencast');
    } catch (_) {}
    await _encoder?.stop();
    if (relay.onClientMessage == _handleClientMessage) {
      relay.onClientMessage = null;
    }
    if (relay.onClientAuthed == _handleClientAuthed) {
      relay.onClientAuthed = null;
    }
  }
}
