/// ffmpeg H.264 编码器（工单 #22）：JPEG 帧经 stdin 管道喂给 ffmpeg 子
/// 进程，stdout 收 H.264 Annex B 裸流并切分为访问单元（AU）。
///
/// 编码器选择：VideoToolbox 硬编（默认，CPU 占用≈0）/ libx264 软编
/// （兼容兜底）/ auto（硬编探测失败自动回退软编）。
///
/// AU 切分启发式（无 B 帧、一进一出）：遇到新的 VCL NAL（type 1/5）且
/// 当前 AU 已有 VCL 时，把之前累积的字节作为一个 AU 发出。SPS/PPS/SEI
/// 随其后的 VCL 归入同一 AU。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// 编码器偏好：auto（硬编失败回退软编）/ hardware（VideoToolbox）/
/// software（libx264）。
enum VideoEncoderKind { auto, hardware, software }

/// ffmpeg H.264 编码器。
class FfmpegVideoEncoder {
  FfmpegVideoEncoder({
    required this.ffmpegPath,
    this.kind = VideoEncoderKind.auto,
    this.gopSize = 24,
    this.nominalFps = 30,
  });

  /// ffmpeg 可执行文件路径（来自 FfmpegLocator）。
  final String ffmpegPath;

  /// 编码器偏好。
  final VideoEncoderKind kind;

  /// GOP 长度（关键帧间隔帧数；@nominalFps 下 48≈1.6s 一个关键帧，
  /// 决定晚到客户端的最长等待）。
  final int gopSize;

  /// 名义帧率（喂给 ffmpeg 的时间基准；实际帧间隔由远程端到达时间决定）。
  final int nominalFps;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  final _auController = StreamController<Uint8List>.broadcast();

  /// 实际生效的编码器名（'h264_videotoolbox' / 'libx264'），start 后有效。
  String? activeEncoder;

  /// 最近一次进程错误输出（stderr 尾部），排障用。
  String lastStderr = '';

  /// 编码出的 H.264 访问单元流（Annex B，含起始码）。
  Stream<Uint8List> get accessUnits => _auController.stream;

  bool get isRunning => _process != null;

  /// 启动编码进程；auto 模式下硬编 2s 内退出视为探测失败，回退软编。
  Future<void> start() async {
    if (_process != null) return;
    if (kind != VideoEncoderKind.software) {
      final ok = await _spawn('h264_videotoolbox');
      if (ok) return;
      if (kind == VideoEncoderKind.hardware) {
        throw StateError('VideoToolbox 硬编启动失败：$lastStderr');
      }
      // auto：回退软编
    }
    final ok = await _spawn('libx264');
    if (!ok) throw StateError('libx264 软编启动失败：$lastStderr');
  }

  Future<bool> _spawn(String encoder) async {
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
      if (encoder == 'libx264') ...[
        '-preset',
        'veryfast',
        '-tune',
        'zerolatency',
      ],
      '-flush_packets', '1', // 每包冲刷输出缓冲，保证实时性
      '-f', 'h264',
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

    final splitter = _AnnexBSplitter(_auController);
    _stdoutSub = process.stdout.listen(splitter.add);

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

/// Annex B 字节流 → 访问单元切分器（_AnnexBSplitter 仅供
/// FfmpegVideoEncoder 内部使用）。
class _AnnexBSplitter {
  _AnnexBSplitter(this._sink);

  final StreamController<Uint8List> _sink;

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
      final nalType = _buf[headerIndex] & 0x1f;
      final isVcl = nalType == 1 || nalType == 5;

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
