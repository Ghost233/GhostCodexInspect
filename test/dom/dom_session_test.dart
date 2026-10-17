import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 极简 WS 消息队列（与 relay_smoke_test 同款单订阅消费模式）。
class _Queue {
  _Queue(Stream<dynamic> stream) {
    _sub = stream.listen((e) {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(e);
      } else {
        _buffer.add(e);
      }
    }, onDone: () {
      while (_waiters.isNotEmpty) {
        _waiters.removeAt(0).completeError(StateError('连接已关闭'));
      }
    });
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

/// 可控 FakeCdpPage：binding 流由测试推入，send/evaluate 记录调用。
class FakeCdpPage extends CdpPage {
  final bindingController = StreamController<String>();
  final sent = <(String, Map<String, dynamic>?)>[];
  final evaluated = <String>[];

  @override
  CdpTargetInfo get target => const CdpTargetInfo(
        id: 't1', type: 'page', url: 'file:///fixture', title: 'fixture');

  @override
  Future<Object?> evaluate(String expression) async {
    evaluated.add(expression);
    return null;
  }

  @override
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) async {
    sent.add((method, params));
    return <String, dynamic>{};
  }

  @override
  Future<Stream<String>> exposeBinding(String name) async =>
      bindingController.stream;

  @override
  Stream<ScreencastFrameData> get screencastFrames =>
      const Stream<ScreencastFrameData>.empty();

  @override
  Future<void> close() async {}
}

void main() {
  late Directory staticDir;
  late RelayServer relay;
  late FakeCdpPage page;
  late DomSession session;
  late WebSocketChannel channel;
  late _Queue queue;

  Future<RelayEnvelope> nextEnvelope() async {
    final raw = await queue.next.timeout(const Duration(seconds: 5));
    return RelayEnvelope.decode(raw as String);
  }

  setUp(() async {
    staticDir = await Directory.systemTemp.createTemp('dom_session_web');
    await File('${staticDir.path}/index.html').writeAsString('<html></html>');
    relay = RelayServer(staticDir: staticDir.path);
    await relay.start();
    page = FakeCdpPage();
    session = DomSession(page: page, relay: relay, collectorSource: '// test');

    channel = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${relay.port}/ws'));
    await channel.ready;
    queue = _Queue(channel.stream);
    channel.sink.add(RelayEnvelope(
      channel: RelayChannel.ctrl,
      type: RelayMessageType.auth,
      seq: 0,
      ts: 0,
      data: {'token': relay.token},
    ).encode());
    final authOk = await nextEnvelope();
    expect(authOk.type, RelayMessageType.authOk);

    await session.start();
  });

  tearDown(() async {
    await session.stop();
    await queue.cancel();
    await channel.sink.close();
    await relay.stop();
    if (await staticDir.exists()) await staticDir.delete(recursive: true);
  });

  test('start 注入采集器脚本（addScriptToEvaluateOnNewDocument + evaluate）',
      () {
    expect(
      page.sent.map((c) => c.$1),
      containsAllInOrder(['Page.enable', 'Page.addScriptToEvaluateOnNewDocument']),
    );
    expect(page.evaluated.single, '// test');
  });

  test('采集器批次分类后经 dom 通道广播（meta/full/batch）', () async {
    page.bindingController.add(jsonEncode([
      {'type': 4, 'data': {'href': 'file:///fixture', 'width': 720, 'height': 480}, 'timestamp': 1},
      {'type': 2, 'data': {'node': {}}, 'timestamp': 2},
      {'type': 3, 'data': {'source': 0}, 'timestamp': 3},
    ]));
    await session.firstFullSnapshot.timeout(const Duration(seconds: 5));

    final meta = await nextEnvelope();
    final full = await nextEnvelope();
    final batch = await nextEnvelope();
    expect(meta.channel, RelayChannel.dom);
    expect(meta.type, RelayMessageType.meta);
    expect(full.type, RelayMessageType.full);
    expect(batch.type, RelayMessageType.batch);
    expect((batch.data as List).single['type'], 3);

    final status = session.status();
    expect(status.active, isTrue);
    expect(status.batchesReceived, 1);
    expect(status.envelopesSent, 3);
  });

  test('非法批次计数为错误但不中断会话', () async {
    page.bindingController.add('not json');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(session.status().lastError, contains('采集批次非法'));
    // 后续正常批次仍能处理
    page.bindingController.add('[{"type":4,"data":{},"timestamp":1}]');
    final meta = await nextEnvelope();
    expect(meta.type, RelayMessageType.meta);
  });

  test('远程端 ctrl resync 触发页面 __gciResync evaluate', () async {
    channel.sink.add(RelayEnvelope(
      channel: RelayChannel.ctrl,
      type: RelayMessageType.resync,
      seq: 1,
      ts: 0,
      data: const {},
    ).encode());
    await _waitFor(() => page.evaluated.any((e) => e.contains(kResyncFunctionName)));
  });

  test('远程端 input 文本经校验后下发 Input.insertText', () async {
    channel.sink.add(RelayEnvelope(
      channel: RelayChannel.input,
      type: RelayMessageType.input,
      seq: 2,
      ts: 0,
      data: {'kind': 'text', 'text': 'hello'},
    ).encode());
    await _waitFor(() =>
        page.sent.any((c) => c.$1 == 'Input.insertText' && c.$2?['text'] == 'hello'));
    expect(session.status().inputsDispatched, 1);
  });

  test('非法 input payload 被拒且计入 lastError', () async {
    channel.sink.add(RelayEnvelope(
      channel: RelayChannel.input,
      type: RelayMessageType.input,
      seq: 3,
      ts: 0,
      data: {'kind': 'unknown'},
    ).encode());
    await _waitFor(() => session.status().lastError != null);
    expect(session.status().inputsDispatched, 0);
  });

  test('stop 幂等且摘除中转回调', () async {
    await session.stop();
    await session.stop();
    expect(session.isActive, isFalse);
    expect(relay.onClientMessage, isNull);
  });
}

/// 轮询等待条件成立（跨 async 边界的断言）。
Future<void> _waitFor(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待条件超时');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
