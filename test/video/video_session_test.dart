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

  /// 轮询直到条件满足（真实异步等待，超时抛错）。
  Future<void> waitFor(bool Function() cond, {int timeoutSeconds = 5}) async {
    final deadline = DateTime.now().add(Duration(seconds: timeoutSeconds));
    while (!cond()) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('等待条件超时（${timeoutSeconds}s）');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// 建一个已鉴权的 WS 客户端（返回连接与收到的事件流）。
  Future<(WebSocketChannel, Stream<dynamic>)> connectAuthed(
    RelayServer relay,
  ) async {
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
    final stream = ws.stream.asBroadcastStream();
    await stream.firstWhere(
      (e) =>
          e is String &&
          (RelayEnvelope.tryDecode(e)?.type == RelayMessageType.authOk),
    );
    return (ws, stream);
  }

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
    // #27：无观众时不编码，编码器在首个观众鉴权后才启动
    expect(session.status.encoder, isNull);

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
    // 等 authOk 之后再喂帧（#27：auth 触发编码管线启动，等其就绪）
    await waitFor(() => session.status.encoding, timeoutSeconds: 10);

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

  test('VideoSession：无人观看不编码，观众接入启动、离开暂停（#27）', () async {
    final lookup = await locator.find();
    if (!lookup.available) return; // 无 ffmpeg 的机器跳过

    final relay = RelayServer(staticDir: 'assets/web');
    await relay.start();
    addTearDown(relay.stop);

    final page = _FakeCdpPage();
    final session = VideoSession(page: page, relay: relay, locator: locator);
    await session.start();
    addTearDown(session.stop);

    // 无观众：编码管线不启动（无 startScreencast、无编码器）
    expect(session.status.active, isTrue);
    expect(session.status.encoding, isFalse);
    expect(session.status.viewers, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.status.framesEncoded, 0);
    expect(session.status.encoder, isNull);
    expect(page.sent.where((c) => c.$1 == 'Page.startScreencast'), isEmpty);

    // 首个观众接入 → 编码启动
    final (ws, stream) = await connectAuthed(relay);
    expect(session.status.viewers, 1);
    await waitFor(() => session.status.encoding, timeoutSeconds: 10);
    expect(session.status.encoder, isNotNull);
    expect(page.sent.where((c) => c.$1 == 'Page.startScreencast'), isNotEmpty);

    // 喂帧确认真的在编码（生成 1 张真实小 JPEG 复用）
    final one = await Process.run(lookup.path!, [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=64x64:rate=1,format=yuv420p',
      '-frames:v',
      '1',
      '-f',
      'image2pipe',
      '-vcodec',
      'mjpeg',
      '-',
    ], stdoutEncoding: null);
    final tinyJpeg = base64Encode(one.stdout as List<int>);
    for (var i = 0; i < 3; i++) {
      page.frameController.add(
        ScreencastFrameData(data: tinyJpeg, sessionId: i, metadata: const {}),
      );
    }
    await waitFor(() => session.status.framesEncoded >= 3);
    expect(page.sent.where((c) => c.$1 == 'Page.screencastFrameAck').length, 3);

    // 观众离开 → 编码暂停（stopScreencast 下发、编码器回收）
    await ws.sink.close();
    await waitFor(() => !session.status.encoding, timeoutSeconds: 10);
    expect(session.status.viewers, 0);
    expect(session.status.encoder, isNull);
    expect(page.sent.where((c) => c.$1 == 'Page.stopScreencast'), isNotEmpty);

    // 再次接入 → 编码恢复（重启编码器与 screencast）
    final (ws2, stream2) = await connectAuthed(relay);
    await waitFor(() => session.status.encoding, timeoutSeconds: 10);
    expect(
      page.sent.where((c) => c.$1 == 'Page.startScreencast').length,
      greaterThanOrEqualTo(2),
    );
    await ws2.sink.close();
    await stream.drain<void>();
    await stream2.drain<void>();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('远程端 ctrl setViewport 覆盖页面视口并重发 meta（自适应跟随）', () async {
    final lookup = await locator.find();
    if (!lookup.available) return; // 无 ffmpeg 的机器跳过

    final relay = RelayServer(staticDir: 'assets/web');
    await relay.start();
    addTearDown(relay.stop);
    final page = _FakeCdpPage();
    final session = VideoSession(page: page, relay: relay, locator: locator);
    await session.start();
    addTearDown(session.stop);

    final (ws, stream) = await connectAuthed(relay);
    await waitFor(() => session.status.encoding, timeoutSeconds: 10);

    ws.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.setViewport,
        seq: 1,
        ts: 0,
        data: {'width': 1600, 'height': 900},
      ).encode(),
    );
    await waitFor(
      () => page.sent.any((c) => c.$1 == 'Emulation.setDeviceMetricsOverride'),
    );
    final call = page.sent.firstWhere(
      (c) => c.$1 == 'Emulation.setDeviceMetricsOverride',
    );
    expect(call.$2, {
      'width': 1600,
      'height': 900,
      'deviceScaleFactor': 1,
      'mobile': false,
    });

    // 非法尺寸丢弃
    final before = page.sent
        .where((c) => c.$1 == 'Emulation.setDeviceMetricsOverride')
        .length;
    ws.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.setViewport,
        seq: 2,
        ts: 0,
        data: {'width': 10, 'height': 10},
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      page.sent
          .where((c) => c.$1 == 'Emulation.setDeviceMetricsOverride')
          .length,
      before,
    );

    // stop 恢复原视口
    await session.stop();
    expect(
      page.sent.any((c) => c.$1 == 'Emulation.clearDeviceMetricsOverride'),
      isTrue,
    );
    await ws.sink.close();
    await stream.drain<void>();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('远程端 ctrl setFrameRate 重启编码管线应用新帧率并在 meta 回显', () async {
    final lookup = await locator.find();
    if (!lookup.available) return; // 无 ffmpeg 的机器跳过

    final relay = RelayServer(staticDir: 'assets/web');
    await relay.start();
    addTearDown(relay.stop);
    final page = _FakeCdpPage();
    final session = VideoSession(page: page, relay: relay, locator: locator);
    await session.start();
    addTearDown(session.stop);
    expect(session.status.frameRate, 30); // 默认 30fps

    final (ws, stream) = await connectAuthed(relay);
    // 收集后续 videoMeta（验证 fps 回显）
    final metas = <Map<String, dynamic>>[];
    stream.listen((e) {
      if (e is! String) return;
      final env = RelayEnvelope.tryDecode(e);
      if (env != null &&
          env.type == RelayMessageType.videoMeta &&
          env.data is Map) {
        metas.add((env.data as Map).cast<String, dynamic>());
      }
    });
    await waitFor(() => session.status.encoding, timeoutSeconds: 10);
    // 默认 30fps → everyNthFrame=2（合成器源 ~60fps）
    final firstStart = page.sent.firstWhere(
      (c) => c.$1 == 'Page.startScreencast',
    );
    expect(firstStart.$2?['everyNthFrame'], 2);

    // 切 60fps：管线重启（stopScreencast → startScreencast nth=1）
    ws.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.setFrameRate,
        seq: 1,
        ts: 0,
        data: {'fps': 60},
      ).encode(),
    );
    await waitFor(
      () => page.sent.where((c) => c.$1 == 'Page.startScreencast').length >= 2,
    );
    expect(session.status.frameRate, 60);
    final secondStart = page.sent
        .where((c) => c.$1 == 'Page.startScreencast')
        .last;
    expect(secondStart.$2?['everyNthFrame'], 1);
    expect(page.sent.any((c) => c.$1 == 'Page.stopScreencast'), isTrue);
    // meta 回显新帧率（其余远程端据此同步选择器）
    await waitFor(() => metas.any((m) => m['frameRate'] == 60));

    // 非法值（0 / 61 / 非数字）丢弃，管线不重启
    var starts = page.sent.where((c) => c.$1 == 'Page.startScreencast').length;
    var seq = 2;
    for (final bad in <Object>[0, 61, 'fast']) {
      ws.sink.add(
        RelayEnvelope(
          channel: RelayChannel.ctrl,
          type: RelayMessageType.setFrameRate,
          seq: seq++,
          ts: 0,
          data: {'fps': bad},
        ).encode(),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(
      page.sent.where((c) => c.$1 == 'Page.startScreencast').length,
      starts,
    );
    expect(session.status.frameRate, 60);

    // 切 15fps：nth=4
    ws.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.setFrameRate,
        seq: 5,
        ts: 0,
        data: {'fps': 15},
      ).encode(),
    );
    await waitFor(
      () => page.sent.where((c) => c.$1 == 'Page.startScreencast').length >= 3,
    );
    expect(
      page.sent
          .where((c) => c.$1 == 'Page.startScreencast')
          .last
          .$2?['everyNthFrame'],
      4,
    );
    expect(session.status.frameRate, 15);

    await ws.sink.close();
    await stream.drain<void>();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
