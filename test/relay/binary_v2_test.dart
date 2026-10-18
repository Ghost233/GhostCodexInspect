import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 信封 v2 二进制帧（工单 #15）：编解码纯函数 + 真中继按能力协商分发。
void main() {
  group('encodeBinaryEnvelope / decodeBinaryEnvelope', () {
    test('往返一致：通道/类型/seq/ts/payload 全部还原', () {
      final payload = Uint8List.fromList([1, 2, 3, 250, 0]);
      final raw = encodeBinaryEnvelope(
        RelayChannel.frame,
        RelayMessageType.frame,
        42,
        payload,
        ts: 1730000000000,
      );
      final decoded = decodeBinaryEnvelope(raw);
      expect(decoded.channel, RelayChannel.frame);
      expect(decoded.type, RelayMessageType.frame);
      expect(decoded.seq, 42);
      expect(decoded.ts, 1730000000000);
      expect(decoded.payload, payload);
    });

    test('头部布局：版本/通道 id/类型 id/seq ts 小端', () {
      final raw = encodeBinaryEnvelope(
          RelayChannel.dom, RelayMessageType.batch, 0x01020304,
          Uint8List(0), ts: 5);
      expect(raw[0], 2); // 版本
      expect(raw[1], 1); // dom
      expect(raw[2], 4); // batch
      expect(raw.sublist(3, 7), [4, 3, 2, 1]); // seq 小端
      expect(raw.length, kBinaryHeaderLength);
    });

    test('坏帧拒绝：过短/坏版本/未知通道/未知类型', () {
      Uint8List base() => encodeBinaryEnvelope(
          RelayChannel.dom, RelayMessageType.full, 0, Uint8List(0));

      expect(() => decodeBinaryEnvelope(Uint8List(3)),
          throwsA(isA<RelayEnvelopeFormatException>()));
      final badVersion = base()..[0] = 9;
      expect(() => decodeBinaryEnvelope(badVersion),
          throwsA(isA<RelayEnvelopeFormatException>()));
      final badChannel = base()..[1] = 99;
      expect(() => decodeBinaryEnvelope(badChannel),
          throwsA(isA<RelayEnvelopeFormatException>()));
      final badType = base()..[2] = 99;
      expect(() => decodeBinaryEnvelope(badType),
          throwsA(isA<RelayEnvelopeFormatException>()));
    });
  });

  group('中继按能力协商分发', () {
    late Directory staticDir;
    late RelayServer server;

    setUp(() async {
      staticDir = await Directory.systemTemp.createTemp('relay_v2_web');
      await File('${staticDir.path}/index.html')
          .writeAsString('<html><body>远程端占位</body></html>');
      server = RelayServer(
        staticDir: staticDir.path,
        authTimeout: const Duration(seconds: 2),
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

    /// 连接+鉴权，返回 (channel, 广播流)。WS 流是单订阅的：authOk 等待
    /// 与后续收帧必须共用 asBroadcastStream 转化后的流。
    Future<(WebSocketChannel, Stream<dynamic>)> connectAndAuth(
        {List<String>? caps}) async {
      final channel = WebSocketChannel.connect(wsUri());
      await channel.ready;
      final stream = channel.stream.asBroadcastStream();
      channel.sink.add(RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': server.token, 'caps': ?caps},
      ).encode());
      // 等 authOk
      final authOk = jsonDecode(await stream
          .firstWhere((e) => e is String && e.contains('"authOk"'))
          .timeout(const Duration(seconds: 5))) as Map<String, Object?>;
      expect((authOk['data'] as Map)['caps'], contains(kBinaryCapability));
      return (channel, stream);
    }

    test('声明 bin.v2 的客户端收二进制帧，未声明的旧客户端回落文本帧',
        () async {
      final (v2, v2Stream) = await connectAndAuth(caps: [kBinaryCapability]);
      final (v1, v1Stream) = await connectAndAuth();

      final v2First = v2Stream.first.timeout(const Duration(seconds: 5));
      final v1First = v1Stream.first.timeout(const Duration(seconds: 5));

      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
      server.broadcast(
        RelayChannel.frame,
        RelayMessageType.frame,
        {'data': base64Encode(jpeg), 'metadata': const {}},
        binaryPayload: jpeg,
      );

      final v2Raw = await v2First;
      expect(v2Raw, isA<Uint8List>());
      final decoded = decodeBinaryEnvelope(v2Raw as Uint8List);
      expect(decoded.channel, RelayChannel.frame);
      expect(decoded.type, RelayMessageType.frame);
      expect(decoded.payload, jpeg);

      final v1Raw = await v1First;
      expect(v1Raw, isA<String>());
      final envelope = RelayEnvelope.decode(v1Raw as String);
      expect(envelope.type, RelayMessageType.frame);
      expect((envelope.data as Map)['data'], base64Encode(jpeg));

      await v2.sink.close();
      await v1.sink.close();
    });

    test('不带 binaryPayload 的广播对所有客户端仍走文本帧', () async {
      final (v2, v2Stream) = await connectAndAuth(caps: [kBinaryCapability]);
      final first = v2Stream.first.timeout(const Duration(seconds: 5));
      server.broadcast(RelayChannel.ctrl, RelayMessageType.pong, {'n': 1});
      final envelope = RelayEnvelope.decode(await first as String);
      expect(envelope.type, RelayMessageType.pong);
      await v2.sink.close();
    });
  });
}
