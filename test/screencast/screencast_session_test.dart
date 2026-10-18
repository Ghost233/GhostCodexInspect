import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/screencast/screencast.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 极简 WS 消息队列（与 dom_session_test 同款单订阅消费模式）。
class _Queue {
  _Queue(Stream<dynamic> stream) {
    _sub = stream.listen(
      (e) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(e);
        } else {
          _buffer.add(e);
        }
      },
      onDone: () {
        while (_waiters.isNotEmpty) {
          _waiters.removeAt(0).completeError(StateError('连接已关闭'));
        }
      },
    );
  }

  final _buffer = <dynamic>[];
  final _waiters = <Completer<dynamic>>[];
  late final StreamSubscription<dynamic> _sub;

  Future<dynamic> get next {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<dynamic>();
    _waiters.add(c);
    return c.future;
  }

  Future<void> cancel() => _sub.cancel();
}

/// 可控 FakeCdpPage：帧流由测试推入，send/evaluate 记录调用。
class _FakeCdpPage extends CdpPage {
  final frameController = StreamController<ScreencastFrameData>.broadcast();
  final sent = <(String, Map<String, dynamic>?)>[];
  final evaluated = <String>[];

  @override
  CdpTargetInfo get target => const CdpTargetInfo(
    id: 't1',
    type: 'page',
    url: 'file:///fixture',
    title: 'fixture',
  );

  @override
  Future<Object?> evaluate(String expression) async {
    evaluated.add(expression);
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
    if (method == 'Page.captureScreenshot') {
      return {'data': base64Encode(utf8.encode('synthetic-jpeg'))};
    }
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

ScreencastFrameData _frame(int sessionId) => ScreencastFrameData(
  data: base64Encode(utf8.encode('jpeg-bytes-$sessionId')),
  sessionId: sessionId,
  metadata: const {'deviceWidth': 720, 'deviceHeight': 480},
);

void main() {
  late Directory staticDir;
  late RelayServer relay;
  late _FakeCdpPage page;
  late ScreencastSession session;
  late WebSocketChannel channel;
  late _Queue queue;

  Future<RelayEnvelope> nextEnvelope() async {
    final raw = await queue.next.timeout(const Duration(seconds: 5));
    return RelayEnvelope.decode(raw as String);
  }

  setUp(() async {
    staticDir = await Directory.systemTemp.createTemp('screencast_web');
    await File('${staticDir.path}/index.html').writeAsString('<html></html>');
    relay = RelayServer(staticDir: staticDir.path);
    await relay.start();
    page = _FakeCdpPage();
    session = ScreencastSession(page: page, relay: relay);

    channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/ws'),
    );
    await channel.ready;
    queue = _Queue(channel.stream);
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': relay.token},
      ).encode(),
    );
    final authOk = await nextEnvelope();
    expect(authOk.type, RelayMessageType.authOk);
  });

  tearDown(() async {
    await session.stop();
    await queue.cancel();
    await channel.sink.close();
    await relay.stop();
    if (await staticDir.exists()) await staticDir.delete(recursive: true);
  });

  test('start 依次 Page.enable、读视口 meta、startScreencast（jpeg）', () async {
    await session.start();
    expect(
      page.sent.map((c) => c.$1),
      containsAllInOrder(['Page.enable', 'Page.startScreencast']),
    );
    final startParams = page.sent
        .firstWhere((c) => c.$1 == 'Page.startScreencast')
        .$2!;
    expect(startParams['format'], 'jpeg');
    expect(startParams['quality'], 60);

    // 视口 meta 走 frame 通道 meta 信封（JSON 字符串，远程端再 parse）。
    final meta = await nextEnvelope();
    expect(meta.channel, RelayChannel.frame);
    expect(meta.type, RelayMessageType.meta);
    expect(jsonDecode(meta.data as String), {
      'viewportWidth': 720,
      'viewportHeight': 480,
      'dpr': 1,
    });
  });

  test('帧广播到 frame 通道并立即回执 ack', () async {
    await session.start();
    await nextEnvelope(); // 启动 meta
    await nextEnvelope(); // 启动补种 meta（#17）
    await nextEnvelope(); // 启动补种合成帧（#17）
    page.frameController.add(_frame(7));
    final frame = await nextEnvelope();
    expect(frame.channel, RelayChannel.frame);
    expect(frame.type, RelayMessageType.frame);
    expect((frame.data as Map)['sessionId'], isNull);
    expect((frame.data as Map)['metadata'], {
      'deviceWidth': 720,
      'deviceHeight': 480,
    });
    await _waitFor(
      () => page.sent.any(
        (c) => c.$1 == 'Page.screencastFrameAck' && c.$2?['sessionId'] == 7,
      ),
    );
    await session.firstFrame.timeout(const Duration(seconds: 5));
    expect(session.status().framesSent, 1);
  });

  test('远程端 input 经校验后下发可信输入', () async {
    await session.start();
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.input,
        type: RelayMessageType.input,
        seq: 1,
        ts: 0,
        data: {'kind': 'mouse', 'action': 'down', 'x': 10, 'y': 20},
      ).encode(),
    );
    await _waitFor(
      () => page.sent.any(
        (c) =>
            c.$1 == 'Input.dispatchMouseEvent' &&
            c.$2?['type'] == 'mousePressed' &&
            c.$2?['x'] == 10,
      ),
    );
    expect(session.status().inputsDispatched, 1);
  });

  test('晚到客户端鉴权成功后补发 meta + 合成帧', () async {
    await session.start();
    await nextEnvelope(); // 首位客户端连接前的启动 meta

    final late = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/ws'),
    );
    await late.ready;
    final lateQueue = _Queue(late.stream);
    late.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': relay.token},
      ).encode(),
    );
    try {
      final authOk = RelayEnvelope.decode(
        await lateQueue.next.timeout(const Duration(seconds: 5)) as String,
      );
      expect(authOk.type, RelayMessageType.authOk);
      final meta = RelayEnvelope.decode(
        await lateQueue.next.timeout(const Duration(seconds: 5)) as String,
      );
      expect(meta.channel, RelayChannel.frame);
      expect(meta.type, RelayMessageType.meta);
      final frame = RelayEnvelope.decode(
        await lateQueue.next.timeout(const Duration(seconds: 5)) as String,
      );
      expect(frame.type, RelayMessageType.frame);
      expect((frame.data as Map)['metadata'], {'synthetic': true});
    } finally {
      await lateQueue.cancel();
      await late.sink.close();
    }
  });

  test('启动即补一帧合成帧：画面静止时远程端也立即出图（#17）', () async {
    await session.start();
    // CDP screencast 只在画面变化时出帧；不推任何真实帧，
    // 启动路径的补种应让已连接客户端立刻收到 meta + 合成帧。
    await nextEnvelope(); // 启动 meta
    await nextEnvelope(); // 补种 meta
    final frame = await nextEnvelope();
    expect(frame.channel, RelayChannel.frame);
    expect(frame.type, RelayMessageType.frame);
    expect((frame.data as Map)['metadata'], {'synthetic': true});
  });

  test('中转回调被占用时 start 抛 StateError（互斥约定）', () async {
    relay.onClientMessage = (_, _) {};
    await expectLater(session.start(), throwsStateError);
    relay.onClientMessage = null;
  });

  test('stop 幂等：stopScreencast 且摘除回调', () async {
    await session.start();
    await session.stop();
    await session.stop();
    expect(session.isActive, isFalse);
    expect(page.sent.map((c) => c.$1), contains('Page.stopScreencast'));
    expect(relay.onClientMessage, isNull);
  });
}

/// 轮询等待条件成立（跨 async 边界的断言）。
Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
