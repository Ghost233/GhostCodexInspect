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
