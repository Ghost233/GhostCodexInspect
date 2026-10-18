import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/video/video.dart';

void main() {
  group('FfmpegInstaller.parseLine', () {
    test('curl 计量行解析出百分比', () {
      final (phase, percent) = FfmpegInstaller.parseLine(
        '##########                                        36.1%',
        'downloading',
      );
      expect(phase, 'downloading');
      expect(percent, closeTo(36.1, 0.01));
    });

    test('Downloading 日志行无百分比', () {
      final (phase, percent) = FfmpegInstaller.parseLine(
        '==> Downloading https://ghcr.io/v2/homebrew/core/ffmpeg/blobs/sha256:abc',
        'downloading',
      );
      expect(phase, 'downloading');
      expect(percent, isNull);
    });

    test('Pouring/Installing 切到 installing 阶段并清空百分比', () {
      for (final line in [
        '==> Pouring ffmpeg--9.0.2.arm64_sequoia.bottle.tar.gz',
        '==> Installing ffmpeg',
      ]) {
        final (phase, percent) = FfmpegInstaller.parseLine(line, 'downloading');
        expect(phase, 'installing');
        expect(percent, isNull);
      }
    });

    test('普通行保持阶段', () {
      final (phase, percent) = FfmpegInstaller.parseLine(
        'some random output',
        'installing',
      );
      expect(phase, 'installing');
      expect(percent, isNull);
    });
  });

  group('FfmpegInstaller（真 brew 冒烟）', () {
    test('brew install ffmpeg（已装则快速走完）', () async {
      const installer = FfmpegInstaller();
      final brew = await installer.findBrew();
      if (!brew.available) return; // 无 brew 机器跳过
      final phases = <String>[];
      await for (final p in installer.install(brew.path!)) {
        phases.add(p.phase);
        if (phases.length > 100000) break; // 防失控
      }
      expect(phases.last, 'done');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
