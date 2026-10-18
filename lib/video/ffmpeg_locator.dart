/// ffmpeg 探测（工单 #22）：不内嵌 ffmpeg，依赖用户 brew 安装。
/// 宿主 UI 提供一键安装与复制指令；探测结果驱动编码器状态卡与
/// 「视频流」模式可用性。
library;

import 'dart:io';

/// ffmpeg 探测结果。
class FfmpegLookup {
  const FfmpegLookup.found(this.path) : available = true;
  const FfmpegLookup.missing() : path = null, available = false;

  /// ffmpeg 可执行文件绝对路径（available=false 时为 null）。
  final String? path;

  /// 是否可用。
  final bool available;
}

/// ffmpeg 定位器：PATH（which）→ Homebrew 常见安装位。
class FfmpegLocator {
  const FfmpegLocator();

  /// brew 安装命令（一键安装按钮与复制指令共用的唯一文案源）。
  static const installCommand = 'brew install ffmpeg';

  /// 探测 ffmpeg；找不到返回 [FfmpegLookup.missing]。
  Future<FfmpegLookup> find() async {
    // PATH 查找
    try {
      final result = await Process.run('which', ['ffmpeg']);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty && await File(path).exists()) {
          return FfmpegLookup.found(path);
        }
      }
    } catch (_) {
      // which 不可用，继续查常见路径
    }
    // Homebrew 常见安装位（GUI 应用 PATH 不含 /opt/homebrew/bin）
    for (final candidate in const [
      '/opt/homebrew/bin/ffmpeg',
      '/usr/local/bin/ffmpeg',
    ]) {
      if (await File(candidate).exists()) {
        return FfmpegLookup.found(candidate);
      }
    }
    return const FfmpegLookup.missing();
  }
}

/// 单个编码器的探测结果（#25 编码能力矩阵）。
class EncoderCapability {
  const EncoderCapability({
    required this.name,
    required this.codec,
    required this.hardware,
    required this.available,
  });

  /// ffmpeg 编码器名（如 'h264_videotoolbox'）。
  final String name;

  /// 对应编码格式 wireTag（'h264'/'hevc'/'av1'）。
  final String codec;

  /// 是否硬编（VideoToolbox）。
  final bool hardware;

  /// ffmpeg 构建中是否存在该编码器。
  final bool available;
}

/// 探测 ffmpeg 构建内的视频编码器清单（解析 `-encoders` 输出）。
///
/// 只反映「编译进 ffmpeg」的能力；硬编真实可用性以会话启动时的
/// 2s 探测回退为准（见 FfmpegVideoEncoder）。
Future<List<EncoderCapability>> probeEncoderCapabilities(
  String ffmpegPath,
) async {
  const watch = {
    'h264_videotoolbox': ('h264', true),
    'libx264': ('h264', false),
    'hevc_videotoolbox': ('hevc', true),
    'libx265': ('hevc', false),
    'libsvtav1': ('av1', false),
  };
  try {
    final result = await Process.run(ffmpegPath, ['-hide_banner', '-encoders']);
    final text = '${result.stdout}\n${result.stderr}';
    return [
      for (final entry in watch.entries)
        EncoderCapability(
          name: entry.key,
          codec: entry.value.$1,
          hardware: entry.value.$2,
          available: RegExp('\\b${entry.key}\\b').hasMatch(text),
        ),
    ];
  } catch (_) {
    return const [];
  }
}
