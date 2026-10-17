import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 集成冒烟：真实启动中转（127.0.0.1 临时端口），用 web_socket_channel
/// 客户端验证令牌鉴权与 ctrl 通道收发。
///
/// 注意：WebSocketChannel.stream 是单订阅流，每个连接用 [_MessageQueue]
/// 统一消费（多次 .first/.drain 会直接冲突）。

/// 极简消息队列：单订阅消费 WS 流，缓冲先到消息，支持按序取与等到关闭。
/// （不引 package:async 的 StreamQueue，避免为测试新增依赖声明。）
class _MessageQueue {
  _MessageQueue(Stream<dynamic> stream) {
    _sub = stream.listen(
      (event) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
        } else {
          _buffer.add(event);
        }
      },
      onDone: () {
        _done = true;
        while (_waiters.isNotEmpty) {
          _waiters.removeAt(0).completeError(StateError('连接已关闭'));
        }
        if (!_doneCompleter.isCompleted) _doneCompleter.complete();
      },
      onError: (Object e) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).completeError(e);
        } else {
          _buffer.addError(e);
        }
      },
    );
  }

  /// 已到未取的消息（或错误）。
  final List<Object> _buffer = [];
  final _waiters = <Completer<dynamic>>[];
  final _doneCompleter = Completer<void>();
  late final StreamSubscription<dynamic> _sub;
  bool _done = false;

  /// 取下一条消息；连接已关且无缓冲时抛 StateError。
  Future<dynamic> get next {
    if (_buffer.isNotEmpty) {
      final event = _buffer.removeAt(0);
      return event is _QueueError
          ? Future<dynamic>.error(event.error)
          : Future<dynamic>.value(event);
    }
    if (_done) return Future<dynamic>.error(StateError('连接已关闭'));
    final completer = Completer<dynamic>();
    _waiters.add(completer);
    return completer.future;
  }

  /// 等连接关闭并清空缓冲。
  Future<void> get closed async {
    await _doneCompleter.future;
    _buffer.clear();
  }

  Future<void> cancel() => _sub.cancel();
}

class _QueueError {
  _QueueError(this.error);
  final Object error;
}

extension on List<Object> {
  void addError(Object e) => add(_QueueError(e));
}

void main() {
  late Directory staticDir;
  late RelayServer server;

  setUp(() async {
    staticDir = await Directory.systemTemp.createTemp('relay_smoke_web');
    await File('${staticDir.path}/index.html')
        .writeAsString('<html><body>远程端占位</body></html>');
    server = RelayServer(
      staticDir: staticDir.path,
      authTimeout: const Duration(milliseconds: 500),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (await staticDir.exists()) {
      await staticDir.delete(recursive: true);
    }
  });

  Uri wsUri() => Uri.parse('ws://127.0.0.1:${server.port}/ws');

  /// 已连接的客户端：channel + 单订阅消息队列。
  Future<(WebSocketChannel, _MessageQueue)> connect() async {
    final channel = WebSocketChannel.connect(wsUri());
    await channel.ready;
    return (channel, _MessageQueue(channel.stream));
  }

  /// 发送一条 ctrl/auth 首消息信封。
  void sendAuth(WebSocketChannel channel, String token) {
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': token},
      ).encode(),
    );
  }

  Future<RelayEnvelope> nextEnvelope(_MessageQueue queue) async {
    final raw = await queue.next.timeout(const Duration(seconds: 5));
    return RelayEnvelope.decode(raw as String);
  }

  /// 等连接被服务端关闭。
  Future<void> drainClosed(_MessageQueue queue) =>
      queue.closed.timeout(const Duration(seconds: 5));

  test('启动后如实回报状态：运行中、回环地址、端口、零远程端', () {
    final status = server.status();
    expect(status.running, isTrue);
    expect(status.address, '127.0.0.1');
    expect(status.port, isNonZero);
    expect(status.clientCount, 0);
    expect(status.observedAt.isUtc, isTrue);
    // 访问 URL 带 fragment 令牌，fragment 不进 HTTP 请求。
    expect(server.accessUrl.toString(), contains('#t=${server.token}'));
  });

  test('静态伺服：index.html 可取，目录外路径不可达', () async {
    final client = HttpClient();
    addTearDown(client.close);
    final ok = await client.get('127.0.0.1', server.port!, '/');
    final okResp = await ok.close();
    expect(okResp.statusCode, HttpStatus.ok);
    expect(await okResp.transform(utf8.decoder).join(), contains('远程端占位'));

    final traversal = await client.get(
      '127.0.0.1',
      server.port!,
      '/../pubspec.yaml',
    );
    final traversalResp = await traversal.close();
    expect(traversalResp.statusCode, isNot(HttpStatus.ok));
    await traversalResp.drain<void>();
  });

  test('正确令牌：鉴权通过，收到 authOk 带 clientId', () async {
    final (channel, queue) = await connect();
    addTearDown(() => channel.sink.close());
    sendAuth(channel, server.token!);
    final reply = await nextEnvelope(queue);
    expect(reply.channel, RelayChannel.ctrl);
    expect(reply.type, RelayMessageType.authOk);
    expect(reply.seq, 0, reason: '每连接出站 seq 从 0 开始');
    expect((reply.data! as Map)['clientId'], isA<int>());
    expect(server.clientCount, 1);
  });

  test('错误令牌：收到 authErr 后以 4401 关闭', () async {
    final (channel, queue) = await connect();
    sendAuth(channel, 'wrong-token');
    final reply = await nextEnvelope(queue);
    expect(reply.type, RelayMessageType.authErr);
    await drainClosed(queue);
    expect(channel.closeCode, kRelayCloseUnauthorized);
    expect(server.clientCount, 0);
  });

  test('鉴权前发送非 auth 消息：直接以 4401 关闭', () async {
    final (channel, queue) = await connect();
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.input,
        type: RelayMessageType.inc,
        seq: 0,
        ts: 0,
        data: {'kind': 'click'},
      ).encode(),
    );
    await drainClosed(queue);
    expect(channel.closeCode, kRelayCloseUnauthorized);
  });

  test('鉴权超时：500ms 内不发首消息被关闭', () async {
    final (channel, queue) = await connect();
    await drainClosed(queue);
    expect(channel.closeCode, kRelayCloseUnauthorized);
  });

  test('ctrl 通道收发：鉴权后消息回调送达，应答可回客户端', () async {
    // 服务端收到 ctrl 消息原样回一条 ack。
    server.onClientMessage = (clientId, envelope) {
      server.sendTo(clientId, RelayChannel.ctrl, RelayMessageType.meta, {
        'ackFor': envelope.seq,
        'echo': (envelope.data! as Map)['command'],
      });
    };
    final (channel, queue) = await connect();
    addTearDown(() => channel.sink.close());
    sendAuth(channel, server.token!);
    final authOk = await nextEnvelope(queue);
    expect(authOk.type, RelayMessageType.authOk);

    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.inc,
        seq: 1,
        ts: 0,
        data: {'command': 'switch-mode'},
      ).encode(),
    );
    final ack = await nextEnvelope(queue);
    expect(ack.channel, RelayChannel.ctrl);
    expect((ack.data! as Map)['echo'], 'switch-mode');
    expect((ack.data! as Map)['ackFor'], 1);
    expect(ack.seq, 1, reason: 'authOk 已用掉 seq 0');
  });

  test('心跳：鉴权后 ping 收到 pong', () async {
    final (channel, queue) = await connect();
    addTearDown(() => channel.sink.close());
    sendAuth(channel, server.token!);
    await nextEnvelope(queue); // authOk
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.ping,
        seq: 1,
        ts: 0,
      ).encode(),
    );
    final pong = await nextEnvelope(queue);
    expect(pong.type, RelayMessageType.pong);
    expect(pong.channel, RelayChannel.ctrl);
  });

  test('stop 回收端口并踢掉远程端，可再次启动（幂等回收）', () async {
    final (channel, queue) = await connect();
    sendAuth(channel, server.token!);
    await nextEnvelope(queue);
    expect(server.clientCount, 1);

    final oldPort = server.port;
    await server.stop();
    expect(server.isRunning, isFalse);
    expect(server.status().running, isFalse);
    expect(server.accessUrl, isNull);
    // 旧连接被踢掉。
    await drainClosed(queue);

    // 再次启动：新端口/新令牌（模拟 onRecycle 后的重新 start）。
    await server.start();
    expect(server.isRunning, isTrue);
    expect(server.token, isNotNull);
    expect(server.port, isNot(equals(oldPort)));
  });
}
