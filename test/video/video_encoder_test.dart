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
    test('分数 DPR 的奇数像素截图保留内容并编码成偶数尺寸', () async {
      final lookup = await locator.find();
      if (!lookup.available) return;
      final jpeg = await Process.run(lookup.path!, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=size=321x181:rate=1,format=yuv420p',
        '-frames:v',
        '1',
        '-f',
        'image2pipe',
        '-vcodec',
        'mjpeg',
        '-',
      ], stdoutEncoding: null);
      expect(jpeg.exitCode, 0, reason: '${jpeg.stderr}');
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: lookup.path!,
        kind: VideoEncoderKind.software,
        outputSize: (width: 322, height: 182),
      );
      await encoder.start();
      addTearDown(encoder.stop);
      final aus = <int>[];
      final sub = encoder.accessUnits.listen(
        aus.addAll,
        onError: (Object _) {},
      );
      addTearDown(sub.cancel);
      for (var i = 0; i < 12; i++) {
        encoder.writeFrame(Uint8List.fromList(jpeg.stdout as List<int>));
        await Future<void>.delayed(const Duration(milliseconds: 33));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(aus, isNotEmpty, reason: encoder.lastStderr);
      final decode = await Process.start(lookup.path!, [
        '-v',
        'error',
        '-f',
        'h264',
        '-i',
        'pipe:0',
        '-frames:v',
        '1',
        '-f',
        'framehash',
        'pipe:1',
      ]);
      final decoded = decode.stdout.transform(utf8.decoder).join();
      final errors = decode.stderr.transform(utf8.decoder).join();
      decode.stdin.add(aus);
      await decode.stdin.close();
      expect(await decode.exitCode, 0, reason: await errors);
      final metadata = await decoded;
      expect(metadata, contains('#dimensions 0: 322x182'));
      expect(metadata, contains('#sar 0: 1/1'), reason: '方形像素才能保持播放器显示比例');
    });

    test('一张截图只产生一个完整视频帧，不能把编码切片当作帧', () async {
      final lookup = await locator.find();
      if (!lookup.available) return;
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: lookup.path!,
        bitrateKbps: 2000,
        kind: VideoEncoderKind.software,
      );
      await encoder.start();
      addTearDown(encoder.stop);
      final aus = <Uint8List>[];
      final sub = encoder.accessUnits.listen(aus.add);
      addTearDown(sub.cancel);
      final jpeg = await makeJpeg(lookup.path!, 0);
      var accepted = 0;
      for (var i = 0; i < 12; i++) {
        if (encoder.writeFrame(jpeg)) accepted++;
        await Future<void>.delayed(const Duration(milliseconds: 33));
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(aus, isNotEmpty);
      expect(
        aus.length,
        lessThanOrEqualTo(accepted),
        reason: '同一视频帧的多个 VCL 切片必须放在同一个 AU 中',
      );
    });

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
      for (final au in aus.where((au) => nalTypes(au).contains(5))) {
        expect(
          nalTypes(au),
          containsAll(<int>[7, 8]),
          reason: '晚加入的手机也必须在关键帧收到解码参数',
        );
      }
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
