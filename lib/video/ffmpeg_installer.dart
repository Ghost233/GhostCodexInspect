/// ffmpeg 内置安装器：经 Homebrew 安装并解析输出出实时进度。
///
/// brew 的日志行（`==> Downloading` / `==> Pouring` 等）走 stdout；
/// 下载阶段 curl 进度条走 stderr，非 TTY 下输出 `\r` 分隔的计量行
/// （形如 `##########                    36.1%`），从中解析百分比；
/// 进入安装阶段后无百分比，只透传状态行。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 安装进度事件。
class FfmpegInstallProgress {
  const FfmpegInstallProgress({
    required this.phase,
    this.percent,
    required this.line,
  });

  /// 阶段：downloading（有百分比）/ installing / done / failed。
  final String phase;

  /// 下载百分比 0-100；无百分比阶段为 null。
  final double? percent;

  /// 最近一行输出（日志展示）。
  final String line;
}

/// brew 可执行文件定位结果。
class BrewLookup {
  const BrewLookup(this.path) : available = true;
  const BrewLookup.missing() : path = null, available = false;

  final String? path;
  final bool available;
}

/// ffmpeg 安装器。
class FfmpegInstaller {
  const FfmpegInstaller();

  /// 定位 brew：PATH → /opt/homebrew（Apple Silicon）→ /usr/local（Intel）。
  Future<BrewLookup> findBrew() async {
    try {
      final result = await Process.run('which', ['brew']);
      final path = '${result.stdout}'.trim();
      if (result.exitCode == 0 && path.isNotEmpty) return BrewLookup(path);
    } catch (_) {}
    for (final candidate in const [
      '/opt/homebrew/bin/brew',
      '/usr/local/bin/brew',
    ]) {
      if (File(candidate).existsSync()) return BrewLookup(candidate);
    }
    return const BrewLookup.missing();
  }

  /// 从原始输出行解析阶段与百分比（纯函数，单测覆盖）。
  ///
  /// 返回 (phase, percent)；percent 无进度信息时为 null。
  static (String, double?) parseLine(String line, String currentPhase) {
    final percentMatch = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
    final percent = percentMatch != null
        ? double.tryParse(percentMatch.group(1)!)
        : null;
    var phase = currentPhase;
    if (line.startsWith('==> Pouring') ||
        line.startsWith('==> Installing') ||
        line.startsWith('==> Caveats')) {
      phase = 'installing';
    }
    return (phase, phase == 'installing' ? null : percent);
  }

  /// 安装 ffmpeg（brew install ffmpeg）。已安装时 brew 提示后快速退出 0。
  ///
  /// 返回进度事件流；进程非零退出时流以 StateError 结束。
  Stream<FfmpegInstallProgress> install(String brewPath) {
    final controller = StreamController<FfmpegInstallProgress>();
    var phase = 'downloading';
    var stdoutDone = false;
    var stderrDone = false;
    Process? process;

    void finishIfDone() {
      if (!stdoutDone || !stderrDone || process == null) return;
      process!.exitCode.then((code) {
        if (controller.isClosed) return;
        if (code == 0) {
          controller.add(
            const FfmpegInstallProgress(phase: 'done', line: '安装完成'),
          );
          controller.close();
        } else {
          controller.addError(StateError('brew install 失败（exit=$code）'));
          controller.close();
        }
      });
    }

    Process.start(brewPath, ['install', 'ffmpeg'])
        .then((p) {
          process = p;
          // stdout：brew 日志行
          p.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  final (newPhase, percent) = parseLine(line, phase);
                  phase = newPhase;
                  if (!controller.isClosed) {
                    controller.add(
                      FfmpegInstallProgress(
                        phase: phase,
                        percent: percent,
                        line: line.trim(),
                      ),
                    );
                  }
                },
                onDone: () {
                  stdoutDone = true;
                  finishIfDone();
                },
                onError: controller.addError,
              );
          // stderr：curl 进度（\r 分隔）
          p.stderr
              .transform(utf8.decoder)
              .listen(
                (chunk) {
                  for (final raw in chunk.split(RegExp(r'[\r\n]+'))) {
                    final line = raw.trim();
                    if (line.isEmpty) continue;
                    final (newPhase, percent) = parseLine(line, phase);
                    phase = newPhase;
                    if (percent != null && !controller.isClosed) {
                      controller.add(
                        FfmpegInstallProgress(
                          phase: phase,
                          percent: percent,
                          line: line,
                        ),
                      );
                    }
                  }
                },
                onDone: () {
                  stderrDone = true;
                  finishIfDone();
                },
                onError: controller.addError,
              );
        })
        .catchError((Object e) {
          if (!controller.isClosed) {
            controller.addError(StateError('无法启动 brew：$e'));
            controller.close();
          }
        });

    return controller.stream;
  }
}
