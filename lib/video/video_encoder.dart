/// ffmpeg 视频编码器（工单 #22/#25）：JPEG 帧经 stdin 管道喂给 ffmpeg 子
/// 进程，stdout 收裸流并切分为访问单元（AU）。
///
/// 编码格式：h264（VT 硬编/libx264 软编）、hevc（VT 硬编/libx265 软编）、
/// av1（libsvtav1 实时软编；VideoToolbox 无 AV1 编码）。vp9 只有 libvpx
/// 软编、实时性差，不支持（#25 决策）。
///
/// 编码器选择：VideoToolbox 硬编（CPU 占用≈0）/ 软编（兼容兜底）/
/// auto（硬编探测失败自动回退软编；av1 无硬编直接软编）。
///
/// AU 切分：h264/hevc 走 Annex B 起始码切分（无 B 帧、一进一出，新 VCL
/// NAL 到来时发出上一 AU）；av1 走 IVF 容器拆帧（帧载荷即低开销 OBU 流）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 编码器偏好：auto（硬编失败回退软编）/ hardware（VideoToolbox）/
/// software（软编）。
enum VideoEncoderKind { auto, hardware, software }

/// 视频编码格式（#25）。wireTag 用于 videoMeta 信封与远程端解析分派。
enum VideoCodecKind {
  h264('H.264', 'h264'),
  hevc('H.265', 'hevc'),
  av1('AV1', 'av1');

  const VideoCodecKind(this.label, this.wireTag);

  final String label;

  /// 线上标识（videoMeta.codec / 远程端解析分派）。
  final String wireTag;

  static VideoCodecKind fromWireTag(String tag) => VideoCodecKind.values
      .firstWhere((c) => c.wireTag == tag, orElse: () => VideoCodecKind.h264);
}

/// 编码格式配置（内部）。
class _CodecPlan {
  const _CodecPlan({
    required this.hwEncoder,
    required this.swEncoder,
    required this.swArgs,
    required this.outFormat,
  });

  /// VideoToolbox 编码器名；null = 该格式无硬编。
  final String? hwEncoder;
  final String swEncoder;

  /// 软编附加参数（低延迟档位）。
  final List<String> swArgs;

  /// ffmpeg 输出封装格式（h264/hevc Annex B；av1 用 ivf 容器便于拆帧）。
  final String outFormat;
}

const _codecPlans = {
  VideoCodecKind.h264: _CodecPlan(
    hwEncoder: 'h264_videotoolbox',
    swEncoder: 'libx264',
    swArgs: ['-preset', 'veryfast', '-tune', 'zerolatency'],
    outFormat: 'h264',
  ),
  VideoCodecKind.hevc: _CodecPlan(
    hwEncoder: 'hevc_videotoolbox',
    swEncoder: 'libx265',
    swArgs: ['-preset', 'ultrafast', '-tune', 'zerolatency'],
    outFormat: 'hevc',
  ),
  VideoCodecKind.av1: _CodecPlan(
    hwEncoder: null,
    swEncoder: 'libsvtav1',
    swArgs: ['-preset', '10'],
    outFormat: 'ivf',
  ),
};

/// ffmpeg 视频编码器。
class FfmpegVideoEncoder {
  FfmpegVideoEncoder({
    required this.ffmpegPath,
    this.codec = VideoCodecKind.h264,
    this.kind = VideoEncoderKind.auto,
    this.bitrateKbps,
    this.gopSize = 12,
    this.nominalFps = 30,
  });

  /// ffmpeg 可执行文件路径（来自 FfmpegLocator）。
  final String ffmpegPath;

  /// 编码格式。
  final VideoCodecKind codec;

  /// 编码器偏好。
  final VideoEncoderKind kind;

  /// 码率（kbps；null = 编码器自动）。
  final int? bitrateKbps;

  /// GOP 长度（关键帧间隔帧数；@nominalFps 下 24≈0.8s 一个关键帧，
  /// 决定晚到客户端的最长等待）。
  final int gopSize;

  /// 名义帧率（喂给 ffmpeg 的时间基准；实际帧间隔由远程端到达时间决定）。
  final int nominalFps;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  final _auController = StreamController<Uint8List>.broadcast();

  /// 实际生效的编码器名（如 'h264_videotoolbox'），start 后有效。
  String? activeEncoder;

  /// 最近一次进程错误输出（stderr 尾部），排障用。
  String lastStderr = '';

  /// 编码出的访问单元流（h264/hevc 为 Annex B 含起始码；av1 为单帧
  /// 低开销 OBU 载荷）。
  Stream<Uint8List> get accessUnits => _auController.stream;

  bool get isRunning => _process != null;

  /// 启动编码进程；auto 模式下硬编 2s 内退出视为探测失败，回退软编。
  Future<void> start() async {
    if (_process != null) return;
    final plan = _codecPlans[codec]!;
    final hw = plan.hwEncoder;
    if (kind != VideoEncoderKind.software && hw != null) {
      final ok = await _spawn(hw, plan);
      if (ok) return;
      if (kind == VideoEncoderKind.hardware) {
        throw StateError('VideoToolbox 硬编（$hw）启动失败：$lastStderr');
      }
      // auto：回退软编
    }
    final ok = await _spawn(plan.swEncoder, plan);
    if (!ok) {
      throw StateError('${plan.swEncoder} 软编启动失败：$lastStderr');
    }
  }

  Future<bool> _spawn(String encoder, _CodecPlan plan) async {
    final args = <String>[
      '-v', 'error',
      // mjpeg 解复用器：为连体 JPEG 流设计，实时出包；image2pipe 会
      // 攒到 stdin EOF 才输出（#22 调试实测）。
      '-f', 'mjpeg',
      '-framerate', '$nominalFps',
      '-i', 'pipe:0',
      '-c:v', encoder,
      '-bf', '0', // 无 B 帧：一进一出，AU 切分与延迟都受益
      '-g', '$gopSize',
      if (bitrateKbps != null) ...['-b:v', '${bitrateKbps}k'],
      // VT 硬编：realtime 提示实时编码（默认 false 会内部攒帧缓冲，
      // 是远程端 1s+ 延迟的主因，2026-10-19 用户反馈）；prio_speed 优先速度
      if (encoder != plan.swEncoder) ...['-realtime', '1', '-prio_speed', '1'],
      if (encoder == plan.swEncoder) ...plan.swArgs,
      '-flush_packets', '1', // 每包冲刷输出缓冲，保证实时性
      '-f', plan.outFormat,
      'pipe:1',
    ];
    Process process;
    try {
      process = await Process.start(ffmpegPath, args);
    } catch (e) {
      lastStderr = '$e';
      return false;
    }
    _process = process;
    activeEncoder = encoder;
    final stderrBuf = StringBuffer();
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen((s) => stderrBuf.write(s));

    final splitter = plan.outFormat == 'ivf'
        ? _IvfSplitter(_auController).add
        : _AnnexBSplitter(
            _auController,
            isVcl: codec == VideoCodecKind.hevc
                ? (header) => ((header >> 1) & 0x3f) < 32
                : (header) {
                    final t = header & 0x1f;
                    return t == 1 || t == 5;
                  },
          ).add;
    _stdoutSub = process.stdout.listen(splitter);

    // 启动探测：2s 内退出 = 该编码器不可用
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 2),
      onTimeout: () => -1, // 仍在运行
    );
    if (exit != -1) {
      lastStderr = stderrBuf.toString();
      await _stdoutSub?.cancel();
      _stdoutSub = null;
      _process = null;
      activeEncoder = null;
      return false;
    }
    unawaited(
      process.exitCode.then((code) {
        if (_process == null) return; // 正常 stop
        lastStderr = stderrBuf.toString();
        _process = null;
        _auController.addError(StateError('ffmpeg 退出（exit=$code）：$lastStderr'));
      }),
    );
    return true;
  }

  /// 喂入一帧 JPEG（CDP screencast 的原始字节，非 base64）。
  void writeFrame(Uint8List jpeg) {
    final process = _process;
    if (process == null) return;
    try {
      process.stdin.add(jpeg);
    } catch (_) {
      // 管道已断，由 exitCode 监听统一处理
    }
  }

  /// 停止编码进程（幂等）。
  Future<void> stop() async {
    final process = _process;
    _process = null;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    if (process != null) {
      try {
        await process.stdin.close();
      } catch (_) {}
      process.kill();
    }
  }

  Future<void> dispose() async {
    await stop();
    await _auController.close();
  }
}

/// Annex B 字节流 → 访问单元切分器（h264/hevc 共用；[isVcl] 按编码
/// 格式判断 NAL 头是否为 VCL）。
class _AnnexBSplitter {
  _AnnexBSplitter(this._sink, {required this._isVcl});

  final StreamController<Uint8List> _sink;
  final bool Function(int header) _isVcl;

  /// 未消费字节缓冲（跨 chunk 保留）。
  final _buf = <int>[];

  /// 当前 AU 在 _buf 中的起始下标；null = 还没见到任何起始码。
  int? _auStart;

  /// 当前 AU 是否已含 VCL NAL。
  bool _auHasVcl = false;

  /// 扫描游标（已处理位置，避免重复扫描）。
  int _pos = 0;

  void add(List<int> chunk) {
    _buf.addAll(chunk);
    _scan();
  }

  /// 从 [from] 起找下一个起始码，返回（起始下标， 前缀长度）或 null。
  (int, int)? _findStartCode(int from) {
    for (var i = from; i + 2 < _buf.length; i++) {
      if (_buf[i] == 0 && _buf[i + 1] == 0) {
        if (_buf[i + 2] == 1) return (i, 3);
        if (i + 3 < _buf.length && _buf[i + 2] == 0 && _buf[i + 3] == 1) {
          return (i, 4);
        }
      }
    }
    return null;
  }

  void _scan() {
    while (true) {
      final found = _findStartCode(_pos);
      if (found == null) break;
      final (start, prefixLen) = found;
      final headerIndex = start + prefixLen;
      if (headerIndex >= _buf.length) break; // NAL 头在下一块，等
      final isVcl = _isVcl(_buf[headerIndex]);

      if (isVcl && _auHasVcl && _auStart != null) {
        // 新 VCL → 上一 AU 完整发出（[_auStart, start)）
        final au = Uint8List.fromList(_buf.sublist(_auStart!, start));
        if (au.isNotEmpty) _sink.add(au);
        _auStart = start;
      } else {
        _auStart ??= start;
      }
      if (isVcl) _auHasVcl = true;
      _pos = headerIndex + 1;
    }
    // 压缩缓冲：丢弃当前 AU 之前的字节
    final auStart = _auStart;
    if (auStart != null && auStart > 0) {
      _buf.removeRange(0, auStart);
      _auStart = 0;
      _pos -= auStart;
    }
    // 防膨胀：长时间无起始码（异常流）截断
    if (_auStart == null && _buf.length > 1 << 20) {
      _buf.removeRange(0, _buf.length - 3);
      _pos = _buf.length - 3;
    }
  }
}

/// IVF 容器拆帧（av1）：32 字节文件头（'DKIF' 魔数）后每帧为
/// [4B LE 长度][8B 时间戳][载荷]；载荷即低开销 OBU 流，直接作为一个 AU。
class _IvfSplitter {
  _IvfSplitter(this._sink);

  final StreamController<Uint8List> _sink;
  final _buf = <int>[];
  bool _headerConsumed = false;

  void add(List<int> chunk) {
    _buf.addAll(chunk);
    if (!_headerConsumed) {
      if (_buf.length < 32) return;
      // 魔数校验（失败也继续——容错，后续帧头会自然对齐或静默丢弃）
      _buf.removeRange(0, 32);
      _headerConsumed = true;
    }
    while (_buf.length >= 12) {
      final size = _buf[0] | (_buf[1] << 8) | (_buf[2] << 16) | (_buf[3] << 24);
      if (size <= 0 || size > 16 << 20) {
        // 异常长度：丢弃一个字节尝试重新对齐
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < 12 + size) return; // 帧体未到齐
      _sink.add(Uint8List.fromList(_buf.sublist(12, 12 + size)));
      _buf.removeRange(0, 12 + size);
    }
  }
}
