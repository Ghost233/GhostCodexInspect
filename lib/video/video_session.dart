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
    required this.encoding,
    required this.viewers,
    required this.encoder,
    required this.framesEncoded,
    required this.ausSent,
    required this.idrAusSent,
    required this.bytesSent,
    this.lastError,
  });

  final bool active;

  /// 编码管线是否在跑（#27：无已鉴权观众时暂停编码）。
  final bool encoding;

  /// 已鉴权观众数。
  final int viewers;

  /// 实际生效的编码器（'h264_videotoolbox' / 'libx264'；未启动为 null）。
  final String? encoder;
  final int framesEncoded;
  final int ausSent;

  /// 其中含 IDR 的 AU 数（关键帧节奏诊断）。
  final int idrAusSent;
  final int bytesSent;
  final String? lastError;
}

/// 编码分辨率模式（#27）：由实际视口宽度换算 startScreencast 的
/// maxWidth（即编码分辨率上限）。
enum VideoResolutionMode {
  /// 跟随视口原始分辨率（不缩放）。
  original('原始（跟随视口）'),

  /// 视口的 2/3（如 1920×1090 视口 → 1280×720 编码）。
  twoThirds('视口的 2/3'),

  /// 视口的 1/2。
  half('视口的 1/2'),

  /// 固定 1280 宽。
  fixed1280('固定 1280 宽');

  const VideoResolutionMode(this.label);

  /// 展示文案。
  final String label;

  /// 持久化标识（枚举名；只能追加不能重排）。
  String get wireTag => name;

  /// 从持久化标识还原（未知值回落默认 twoThirds）。
  static VideoResolutionMode fromWireTag(String tag) =>
      VideoResolutionMode.values.firstWhere(
        (m) => m.name == tag,
        orElse: () => VideoResolutionMode.twoThirds,
      );

  /// 由实际视口宽度计算编码宽度上限（null=不限制）；取偶
  /// （yuv420p 编码要求偶数尺寸）。
  int? maxWidthFor(int viewportWidth) => switch (this) {
    VideoResolutionMode.original => null,
    VideoResolutionMode.twoThirds => _even(viewportWidth * 2 ~/ 3),
    VideoResolutionMode.half => _even(viewportWidth ~/ 2),
    VideoResolutionMode.fixed1280 => 1280,
  };

  static int _even(int v) => v.isEven ? v : v - 1;
}

/// 视频流会话。
///
/// #27：无已鉴权观众时不编码——会话 start 后只挂控制面（输入/页签切换
/// /meta），编码管线（screencast + ffmpeg）在首个观众鉴权时启动、最后
/// 一个观众断开时暂停。
class VideoSession {
  VideoSession({
    required this.page,
    required this.relay,
    this.codec = VideoCodecKind.h264,
    this.encoderKind = VideoEncoderKind.auto,
    this.bitrateKbps = 2000,
    this.quality = 60,
    this.everyNthFrame = 2,
    this.resolutionMode = VideoResolutionMode.twoThirds,
    this.onSwitchRequested,
    this.locator = const FfmpegLocator(),
  });

  final CdpPage page;
  final RelayServer relay;
  final VideoCodecKind codec;
  final VideoEncoderKind encoderKind;

  /// 码率（kbps）。
  final int bitrateKbps;
  final int quality;
  final int everyNthFrame;

  /// 编码分辨率模式（#27）：由实际视口换算 maxWidth。
  final VideoResolutionMode resolutionMode;

  /// #16：远程端请求切换 shell 页面时回调（宿主重建会话）。
  final void Function(String targetId)? onSwitchRequested;

  /// ffmpeg 定位器（可注入 fake 便于测试）。
  final FfmpegLocator locator;

  String? _ffmpegPath;
  FfmpegVideoEncoder? _encoder;
  StreamSubscription<ScreencastFrameData>? _frameSub;
  StreamSubscription<Uint8List>? _auSub;
  bool _active = false;
  bool _encoding = false;
  bool _resumeInFlight = false;
  int _viewportWidth = 0;
  int _viewportHeight = 0;
  int _framesEncoded = 0;
  int _ausSent = 0;
  int _idrAusSent = 0;
  int _bytesSent = 0;
  String? _lastError;
  final _firstAu = Completer<void>();

  bool get isActive => _active;

  /// 编码管线是否在跑（无观众时为 false）。
  bool get isEncoding => _encoding;

  /// 首个 AU 编码完成（E2E 等待点）。
  Future<void> get firstAccessUnit => _firstAu.future;

  VideoSessionStatus get status => VideoSessionStatus(
    active: _active,
    encoding: _encoding,
    viewers: relay.authedClientCount,
    encoder: _encoder?.activeEncoder,
    framesEncoded: _framesEncoded,
    ausSent: _ausSent,
    idrAusSent: _idrAusSent,
    bytesSent: _bytesSent,
    lastError: _lastError,
  );

  /// 启动：互斥守卫 → ffmpeg 预检 → 挂控制面回调 → Page.enable →
  /// 读视口 → videoMeta → 有观众才启动编码管线（#27）。
  Future<void> start() async {
    if (_active) return;
    // 一期互斥约定：与 DOM/画面流会话共享中转回调（#12 决策）
    if (relay.onClientMessage != null || relay.onClientAuthed != null) {
      throw StateError('中转消息回调已被另一会话占用（一期互斥约定：先 stop 另一个会话）');
    }
    // ffmpeg 预检：缺失立即报错，不等到首个观众接入才发现
    final lookup = await locator.find();
    if (!lookup.available) {
      throw StateError('未找到 ffmpeg：请先 ${FfmpegLocator.installCommand}');
    }
    _ffmpegPath = lookup.path!;

    relay.onClientMessage = _handleClientMessage;
    relay.onClientAuthed = _handleClientAuthed;
    relay.onClientDisconnected = _handleClientDisconnected;

    await page.send('Page.enable');
    await _readViewport();
    await _broadcastVideoMeta();
    _active = true;
    if (relay.authedClientCount > 0) {
      await _resumeEncoding();
    }
  }

  Future<void> _readViewport() async {
    final raw = await page.evaluate(
      'JSON.stringify({viewportWidth: innerWidth, viewportHeight: innerHeight})',
    );
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    _viewportWidth = (map['viewportWidth'] as num).toInt();
    _viewportHeight = (map['viewportHeight'] as num).toInt();
  }

  /// 启动编码管线（screencast + ffmpeg）。幂等；encoding=true 时
  /// 编码器一定已就绪。
  Future<void> _resumeEncoding() async {
    if (!_active || _encoding || _resumeInFlight) return;
    _resumeInFlight = true;
    try {
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: _ffmpegPath!,
        codec: codec,
        kind: encoderKind,
        bitrateKbps: bitrateKbps,
      );
      await encoder.start();
      _encoder = encoder;
      _auSub = encoder.accessUnits.listen(
        _onAccessUnit,
        onError: (Object e) => _lastError = '$e',
      );
      final maxWidth = resolutionMode.maxWidthFor(_viewportWidth);
      await page.send('Page.startScreencast', {
        'format': 'jpeg',
        'quality': quality,
        'everyNthFrame': everyNthFrame,
        'maxWidth': ?maxWidth,
      });
      _frameSub = page.screencastFrames.listen(
        _onFrame,
        onError: (Object e) => _lastError = '$e',
      );
      _encoding = true;
      // encoder 名此时才确定，重发 meta 让远程端看到真实编码器
      await _broadcastVideoMeta();
    } catch (e) {
      _lastError = '$e';
      rethrow;
    } finally {
      _resumeInFlight = false;
    }
  }

  /// 暂停编码管线（#27：最后一个观众离开时调用）。幂等。
  Future<void> _pauseEncoding() async {
    if (!_encoding) return;
    _encoding = false;
    await _frameSub?.cancel();
    _frameSub = null;
    await _auSub?.cancel();
    _auSub = null;
    try {
      await page.send('Page.stopScreencast');
    } catch (_) {}
    final encoder = _encoder;
    _encoder = null;
    await encoder?.stop();
  }

  Future<void> _broadcastVideoMeta() async {
    relay.broadcast(RelayChannel.video, RelayMessageType.videoMeta, {
      'codec': codec.wireTag,
      'encoder': _encoder?.activeEncoder ?? 'unknown',
      'viewportWidth': _viewportWidth,
      'viewportHeight': _viewportHeight,
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
    // #27：首个已鉴权观众接入 → 启动编码管线
    if (relay.authedClientCount == 1 && !_encoding) {
      unawaited(
        _resumeEncoding().catchError((Object e) {
          _lastError = '$e';
          return null;
        }),
      );
    }
  }

  void _handleClientDisconnected(int clientId) {
    // #27：最后一个已鉴权观众离开 → 暂停编码管线（省 CPU/带宽）
    if (_active && relay.authedClientCount == 0) {
      unawaited(_pauseEncoding());
    }
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

  /// 停止（幂等）：停编码管线，归还中转回调。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _pauseEncoding();
    if (relay.onClientMessage == _handleClientMessage) {
      relay.onClientMessage = null;
    }
    if (relay.onClientAuthed == _handleClientAuthed) {
      relay.onClientAuthed = null;
    }
    if (relay.onClientDisconnected == _handleClientDisconnected) {
      relay.onClientDisconnected = null;
    }
  }
}
