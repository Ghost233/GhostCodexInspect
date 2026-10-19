/// 视频流会话（工单 #22/#25）：CDP screencast JPEG 帧 → ffmpeg 编码 →
/// video 通道 AU 下发（h264/hevc Annex B；av1 IVF 拆帧 OBU）。
/// 与 DOM 会话互斥（共享中转回调）。
///
/// 晚到客户端：立即补发 videoMeta，画面从下一个关键帧 AU 开始可解码
/// （GOP 48 @ 30fps 名义值，最长等待约 1.6s；远程端在拿到关键帧前
/// 丢弃 delta AU）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/cdp/viewport_override.dart';
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
    this.encodeQueueDepth = 0,
    this.lastFrameLatencyMs = 0,
    this.frameRate = 30,
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

  /// 已喂编码器、尚未出 AU 的帧数（管线深度；持续增长 = 编码端积压，
  /// 端到端延迟同步上涨——writeFrame 无背压的显形指标）。
  final int encodeQueueDepth;

  /// 最近一个 AU 的捕获→广播耗时（ms，CDP screencast 采集时刻起算）。
  final double lastFrameLatencyMs;

  /// 当前目标帧率（远程端 setFrameRate 可调；诊断用）。
  final int frameRate;
  final String? lastError;
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
    // screencast 截帧的 JPEG 质量。q60 的文字振铃噪点会被后续视频编码
    // 忠实保留（2026-10-19 用户实测 20Mbps 仍模糊的根因）；本机/局域网
    // 带宽充足，默认 90
    this.quality = 90,
    int frameRate = 30,
    this.onSwitchRequested,
    this.locator = const FfmpegLocator(),
  }) : _frameRate = frameRate.clamp(1, kMaxFrameRate);

  final CdpPage page;
  final RelayServer relay;
  final VideoCodecKind codec;
  final VideoEncoderKind encoderKind;

  /// 码率（kbps）。
  final int bitrateKbps;

  /// screencast 截帧 JPEG 质量（见构造器注释）。
  final int quality;

  /// 帧率上限（合成器源帧率约 60fps，超过无意义）。
  static const int kMaxFrameRate = 60;

  /// 当前目标帧率（远程端可通过 ctrl setFrameRate 调整，默认 30）。
  int _frameRate;

  /// 当前目标帧率（meta 回显与状态诊断用）。
  int get frameRate => _frameRate;

  /// 目标帧率 → screencast everyNthFrame（源 ~60fps：15→4、30→2、60→1）。
  static int everyNthFrameForFps(int fps) =>
      (kMaxFrameRate / fps).round().clamp(1, kMaxFrameRate);

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

  /// 是否已对页面应用视口覆盖（stop 时据此恢复）。
  bool _viewportOverridden = false;
  int _viewportHeight = 0;
  int _framesEncoded = 0;
  int _ausSent = 0;
  int _idrAusSent = 0;
  int _bytesSent = 0;

  /// 已喂编码器但尚未出 AU 的帧的采集时刻（FIFO；-bf 0 无 B 帧重排，
  /// 进出 1:1）。用于管线深度与捕获→发出延迟观测（2026-10-19 延迟回归
  /// 排查：writeFrame 无背压，积压会在这两个指标上显形）。
  final _captureTimes = Queue<double>();
  double _lastFrameLatencyMs = 0;
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
    encodeQueueDepth: _captureTimes.length,
    lastFrameLatencyMs: _lastFrameLatencyMs,
    frameRate: _frameRate,
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
    // 清掉可能残留的历史视口覆盖：Electron 目标上 setDeviceMetricsOverride
    // 会跨会话粘滞（宿主进程死亡后覆盖仍留在被控页面上，2026-10-19 实测
    // Codex 页残留 1280x1024@1 覆盖）。若不清除，start 时 _readViewport
    // 读到的是旧覆盖值，广播的 meta 就是错的起点。
    try {
      await clearViewportOverride(page);
    } catch (_) {
      // 页面刚启动/已死等场景下失败可忽略，读真实视口即可
    }
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
      // 解除后台/遮挡节流（2026-10-19 操作延迟回归根因）：被控窗口被
      // 遮挡或最小化时 Chromium 合成器节流，visibility=hidden → 无
      // BeginFrame → screencast 断流（真机实测 0 帧/10s），远程端表现为
      // 操作延迟飙升。焦点仿真令页面按前台对待（实测恢复 ~45fps）。
      // 观众走光时 _pauseEncoding 恢复。
      try {
        await page.send('Emulation.setFocusEmulationEnabled', {
          'enabled': true,
        });
      } catch (_) {
        // 旧版 Chromium 无此方法时忽略（节流照常，不阻塞会话）
      }
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: _ffmpegPath!,
        codec: codec,
        kind: encoderKind,
        bitrateKbps: bitrateKbps,
        nominalFps: _frameRate,
      );
      await encoder.start();
      _encoder = encoder;
      _auSub = encoder.accessUnits.listen(
        _onAccessUnit,
        onError: (Object e) => _lastError = '$e',
      );
      // 帧订阅必须先于 startScreencast：期间到达的帧若漏 ack，
      // CDP 流控会停发后续帧（2026-10-19 间歇性帧停滞的根因）
      _frameSub = page.screencastFrames.listen(
        _onFrame,
        onError: (Object e) => _lastError = '$e',
      );
      await page.send('Page.startScreencast', {
        'format': 'jpeg',
        'quality': quality,
        'everyNthFrame': everyNthFrameForFps(_frameRate),
      });
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
    // 恢复页面焦点/节流状态（与 _resumeEncoding 的仿真配对）
    try {
      await page.send('Emulation.setFocusEmulationEnabled', {'enabled': false});
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
      'frameRate': _frameRate,
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
    final captureTs = frame.metadata['timestamp'];
    if (captureTs is num) {
      _captureTimes.addLast(captureTs.toDouble());
      // 编码器卡死时 AU 不再流出，队列只进不出——封顶防内存无界增长
      // （饱和后 encodeQueueDepth 停在 256，仍是积压信号）。
      while (_captureTimes.length > 256) {
        _captureTimes.removeFirst();
      }
    }
  }

  void _onAccessUnit(Uint8List au) {
    _ausSent++;
    if (_captureTimes.isNotEmpty) {
      final ts = _captureTimes.removeFirst();
      _lastFrameLatencyMs =
          (DateTime.now().millisecondsSinceEpoch / 1000 - ts) * 1000;
    }
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

  /// 解析 setFrameRate 请求：{fps: 1..60}，越界/非数字丢弃。
  static int? _parseFrameRate(Object? data) {
    if (data is! Map) return null;
    final fps = data['fps'];
    if (fps is! num) return null;
    final v = fps.round();
    if (v < 1 || v > kMaxFrameRate) return null;
    return v;
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
    // 远程端「自适应」视口跟随（2026-10-19）：覆盖目标页视口为远程
    // 舞台尺寸，内容原生重排；之后重读视口并广播 meta
    if (envelope.channel == RelayChannel.ctrl &&
        envelope.type == RelayMessageType.setViewport) {
      final size = parseViewportRequest(envelope.data);
      if (size == null) return;
      unawaited(
        () async {
          await applyViewportOverride(page, size.width, size.height);
          _viewportOverridden = true;
          await _readViewport();
          await _broadcastVideoMeta();
        }().catchError((Object e) {
          _lastError = '$e';
        }),
      );
      return;
    }
    // 远程端帧率偏好（2026-10-19「15/30/60 可选」需求）：screencast 的
    // everyNthFrame 与编码器 -framerate 都是启动参数，只能重启捕获与编码
    // 管线生效；重启后新 GOP 以 IDR 起，远程端解码器无缝衔接。videoMeta
    // 回显新 frameRate，其余远程端的帧率选择器据此同步。
    if (envelope.channel == RelayChannel.ctrl &&
        envelope.type == RelayMessageType.setFrameRate) {
      final fps = _parseFrameRate(envelope.data);
      if (fps == null || fps == _frameRate) return;
      _frameRate = fps;
      unawaited(
        () async {
          if (_encoding) {
            await _pauseEncoding();
            // 重启期间最后一个观众可能恰好离开：恢复前复查
            if (_active && relay.authedClientCount > 0) {
              await _resumeEncoding(); // 末尾已重发 meta（含新 fps）
              return;
            }
          }
          await _broadcastVideoMeta();
        }().catchError((Object e) {
          _lastError = '$e';
        }),
      );
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

  /// 停止（幂等）：停编码管线，归还中转回调；恢复视口覆盖。
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _pauseEncoding();
    if (_viewportOverridden) {
      _viewportOverridden = false;
      try {
        await clearViewportOverride(page);
      } catch (_) {
        // 页面可能已断开；覆盖随 CDP 会话死亡自动回收
      }
    }
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
