import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/video/video.dart';

/// 生成一帧测试 JPEG（ffmpeg lavfi testsrc2；不同 seed 让画面有变化）。
Future<Uint8List> makeJpeg(String ffmpeg, int seed) async {
  final result = await Process.run(
    ffmpeg,
    [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=320x180:rate=1,format=yuv420p',
      '-frames:v',
      '1',
      '-f',
      'image2pipe',
      '-vcodec',
      'mjpeg',
      '-',
    ],
    stdoutEncoding: null,
    stderrEncoding: null,
  );
  expect(result.exitCode, 0, reason: utf8.decode(result.stderr as List<int>));
  return Uint8List.fromList(result.stdout as List<int>);
}

/// 扫描 AU 内的 NAL 类型集合。
Set<int> nalTypes(Uint8List au) {
  final types = <int>{};
  for (var i = 0; i + 4 < au.length; i++) {
    if (au[i] == 0 &&
        au[i + 1] == 0 &&
        (au[i + 2] == 1 || (au[i + 2] == 0 && au[i + 3] == 1))) {
      final header = au[i + 2] == 1 ? i + 3 : i + 4;
      if (header < au.length) types.add(au[header] & 0x1f);
    }
  }
  return types;
}

void main() {
  const locator = FfmpegLocator();

  group('FfmpegVideoEncoder（真 ffmpeg 集成）', () {
    test('auto 模式启动并编码出含 SPS 与 IDR 的 AU 序列', () async {
      final lookup = await locator.find();
      if (!lookup.available) {
        return; // 无 ffmpeg 的机器整组跳过
      }
      final encoder = FfmpegVideoEncoder(ffmpegPath: lookup.path!);
      await encoder.start();
      expect(encoder.activeEncoder, isNotNull);

      // 预生成 60 帧连体 JPEG（真实节奏喂入；帧数太少时 VideoToolbox
      // 内部缓冲不放行任何输出——调试实测）
      final pool = await Process.run(lookup.path!, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc2=size=320x180:rate=30,format=yuv420p',
        '-frames:v',
        '60',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-',
      ], stdoutEncoding: null);
      final frames = Uint8List.fromList(pool.stdout as List<int>);
      final aus = <Uint8List>[];
      final sub = encoder.accessUnits.listen(aus.add);
      // 按 EOI（FF D9）边界逐帧喂，33ms 节奏
      var off = 0;
      while (off < frames.length) {
        var end = off + 2;
        while (end + 1 < frames.length &&
            !(frames[end] == 0xFF && frames[end + 1] == 0xD9)) {
          end++;
        }
        end = (end + 2).clamp(0, frames.length);
        encoder.writeFrame(Uint8List.sublistView(frames, off, end));
        off = end;
        await Future<void>.delayed(const Duration(milliseconds: 33));
      }
      // 等编码排空
      await Future<void>.delayed(const Duration(seconds: 3));
      await encoder.stop();
      await sub.cancel();

      expect(aus.length, greaterThanOrEqualTo(20), reason: '60 帧应编出 ≥20 个 AU');
      // 首个 AU 必须含 SPS(7)+PPS(8)，且至少一个 AU 含 IDR(5)
      expect(nalTypes(aus.first), containsAll(<int>[7, 8]));
      expect(
        aus.any((au) => nalTypes(au).contains(5)),
        isTrue,
        reason: '至少一个 AU 含 IDR',
      );
      // 每个 AU 最多一个 VCL（切分正确性）
      for (final au in aus) {
        final vclCount = nalTypes(au).where((t) => t == 1 || t == 5).length;
        expect(vclCount, lessThanOrEqualTo(1));
      }
    });

    test('hardware 强制模式在本机可用（VideoToolbox）', () async {
      final lookup = await locator.find();
      if (!lookup.available) return;
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: lookup.path!,
        kind: VideoEncoderKind.hardware,
      );
      await encoder.start();
      expect(encoder.activeEncoder, 'h264_videotoolbox');
      await encoder.stop();
    });

    test('software 强制模式用 libx264', () async {
      final lookup = await locator.find();
      if (!lookup.available) return;
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: lookup.path!,
        kind: VideoEncoderKind.software,
      );
      await encoder.start();
      expect(encoder.activeEncoder, 'libx264');
      await encoder.stop();
    });
  });
}
