import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 可控 FakeCdpPage：帧流由测试推入。
class _FakeCdpPage extends CdpPage {
  final frameController = StreamController<ScreencastFrameData>.broadcast();
  final sent = <(String, Map<String, dynamic>?)>[];

  @override
  CdpTargetInfo get target => const CdpTargetInfo(
    id: 't1',
    type: 'page',
    url: 'file:///fixture',
    title: 'fixture',
  );

  @override
  Future<Object?> evaluate(String expression) async {
    if (expression.contains('viewportWidth')) {
      return '{"viewportWidth":720,"viewportHeight":480,"dpr":1}';
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    sent.add((method, params));
    return <String, dynamic>{};
  }

  @override
  Future<Stream<String>> exposeBinding(String name) async =>
      const Stream<String>.empty();

  @override
  Stream<ScreencastFrameData> get screencastFrames => frameController.stream;

  @override
  Stream<Map<String, dynamic>> get fileChooserOpened =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> close() async {}
}

/// 从连体 MJPEG 字节流按 SOI/EOI 标记拆帧。
List<Uint8List> splitMjpeg(Uint8List data) {
  final frames = <Uint8List>[];
  var start = -1;
  for (var i = 0; i + 1 < data.length; i++) {
    if (data[i] == 0xFF && data[i + 1] == 0xD8) {
      start = i;
    } else if (data[i] == 0xFF && data[i + 1] == 0xD9 && start >= 0) {
      frames.add(Uint8List.sublistView(data, start, i + 2));
      start = -1;
    }
  }
  return frames;
}

void main() {
  const locator = FfmpegLocator();

  test('VideoSession：真 ffmpeg 编码链路，meta + AU 信封广播、stop 幂等', () async {
    final lookup = await locator.find();
    if (!lookup.available) return; // 无 ffmpeg 的机器跳过

    final relay = RelayServer(staticDir: 'assets/web');
    await relay.start();
    addTearDown(relay.stop);

    final page = _FakeCdpPage();
    final session = VideoSession(page: page, relay: relay, locator: locator);
    await session.start();
    addTearDown(session.stop);
    expect(session.status.active, isTrue);
    expect(session.status.encoder, isNotNull);

    // 观察 video 通道信封（二进制 v2 或文本 v1 都收）
    final ws = WebSocketChannel.connect(
      Uri.parse(
        '${relay.accessUrl.toString().replaceFirst('http', 'ws').split('#').first}ws',
      ),
    );
    ws.sink.add(
      jsonEncode({
        'v': 1,
        'ch': 'ctrl',
        't': 'auth',
        'seq': 0,
        'ts': 0,
        'data': {'token': relay.token},
      }),
    );
    final received = <RelayEnvelope>[];
    final binaryAus = <Uint8List>[];
    final sub = ws.stream.listen((e) {
      if (e is String) {
        final env = RelayEnvelope.tryDecode(e);
        if (env != null && env.channel == RelayChannel.video) received.add(env);
      } else if (e is List<int>) {
        final bin = decodeBinaryEnvelope(Uint8List.fromList(e));
        if (bin.type == RelayMessageType.videoFrame) binaryAus.add(bin.payload);
      }
    });
    addTearDown(() async {
      await sub.cancel();
      await ws.sink.close();
    });
    // 等 authOk 之后再喂帧
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 生成 60 帧连体 MJPEG 并推入帧流（VT 内部缓冲需要足够帧数）
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
    final frames = splitMjpeg(Uint8List.fromList(pool.stdout as List<int>));
    expect(frames.length, 60);
    var sessionId = 0;
    for (final frame in frames) {
      page.frameController.add(
        ScreencastFrameData(
          data: base64Encode(frame),
          sessionId: sessionId++,
          metadata: const {},
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 33));
    }
    // 等编码器排空
    await Future<void>.delayed(const Duration(seconds: 3));

    // videoMeta 应已广播（启动一次）
    expect(
      received.where((e) => e.type == RelayMessageType.videoMeta),
      isNotEmpty,
    );
    // AU 信封到达（二进制或文本通道任一）
    final textAus = received
        .where((e) => e.type == RelayMessageType.videoFrame)
        .length;
    expect(textAus + binaryAus.length, greaterThan(20));

    await session.stop();
    await session.stop(); // 幂等
    expect(session.status.active, isFalse);
    // ack 应已发送（帧数 + 合成种子帧）
    expect(
      page.sent.where((c) => c.$1 == 'Page.screencastFrameAck').length,
      greaterThanOrEqualTo(60),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
