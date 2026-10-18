import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/envelope.dart';

void main() {
  group('通道信封编解码往返', () {
    test('每种消息类型 × 每种通道编码后解码还原', () {
      for (final type in RelayMessageType.values) {
        for (final channel in RelayChannel.values) {
          final original = RelayEnvelope(
            channel: channel,
            type: type,
            seq: 42,
            ts: 1730000000000,
            data: const {'hello': 'world', 'n': 1},
          );
          final decoded = RelayEnvelope.decode(original.encode());
          expect(decoded.version, kRelayProtocolVersion);
          expect(decoded.channel, channel);
          expect(decoded.type, type);
          expect(decoded.seq, 42);
          expect(decoded.ts, 1730000000000);
          expect(decoded.data, {'hello': 'world', 'n': 1});
        }
      }
    });

    test('batch 通道载荷为事件数组可往返', () {
      final original = RelayEnvelope(
        channel: RelayChannel.dom,
        type: RelayMessageType.batch,
        seq: 7,
        ts: 1,
        data: const [
          {'type': 3},
          {'type': 5},
        ],
      );
      final decoded = RelayEnvelope.decode(original.encode());
      expect(decoded.data, isA<List>());
      expect((decoded.data! as List).length, 2);
    });

    test('无 data 字段的信封可往返（ping 等）', () {
      final original = RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.ping,
        seq: 0,
        ts: 5,
      );
      expect(original.encode(), isNot(contains('data')));
      final decoded = RelayEnvelope.decode(original.encode());
      expect(decoded.data, isNull);
    });

    test('线格式键名符合协议草案（v/ch/t/seq/ts/data）', () {
      final json = jsonDecode(
        RelayEnvelope(
          channel: RelayChannel.frame,
          type: RelayMessageType.batch,
          seq: 1,
          ts: 2,
          data: 'x',
        ).encode(),
      ) as Map;
      expect(json.keys.toSet(), {'v', 'ch', 't', 'seq', 'ts', 'data'});
      expect(json['v'], 1);
      expect(json['ch'], 'frame');
      expect(json['t'], 'batch');
    });
  });

  group('通道信封解码拒绝非法输入', () {
    String validJson() => jsonEncode({
      'v': 1,
      'ch': 'ctrl',
      't': 'auth',
      'seq': 0,
      'ts': 0,
      'data': {'token': 'x'},
    });

    test('非 JSON 文本被拒绝', () {
      expect(RelayEnvelope.tryDecode('not json'), isNull);
      expect(
        () => RelayEnvelope.decode('not json'),
        throwsA(isA<RelayEnvelopeFormatException>()),
      );
    });

    test('JSON 数组（非对象）被拒绝', () {
      expect(RelayEnvelope.tryDecode('[1,2]'), isNull);
    });

    test('协议版本不符被拒绝', () {
      final json = jsonDecode(validJson()) as Map<String, Object?>..['v'] = 2;
      expect(RelayEnvelope.tryDecode(jsonEncode(json)), isNull);
    });

    test('未知通道被拒绝', () {
      final json = jsonDecode(validJson()) as Map<String, Object?>
        ..['ch'] = 'hologram';
      expect(RelayEnvelope.tryDecode(jsonEncode(json)), isNull);
    });

    test('未知消息类型被拒绝', () {
      final json = jsonDecode(validJson()) as Map<String, Object?>
        ..['t'] = 'explode';
      expect(RelayEnvelope.tryDecode(jsonEncode(json)), isNull);
    });

    test('seq 缺失、负数或非整数被拒绝', () {
      for (final mutate in [
        (Map<String, Object?> j) => j.remove('seq'),
        (Map<String, Object?> j) => j['seq'] = -1,
        (Map<String, Object?> j) => j['seq'] = '0',
      ]) {
        final json = jsonDecode(validJson()) as Map<String, Object?>;
        mutate(json);
        expect(RelayEnvelope.tryDecode(jsonEncode(json)), isNull);
      }
    });

    test('ts 缺失按 0 处理，负 ts 被拒绝', () {
      final missing = jsonDecode(validJson()) as Map<String, Object?>
        ..remove('ts');
      expect(RelayEnvelope.decode(jsonEncode(missing)).ts, 0);
      final negative = jsonDecode(validJson()) as Map<String, Object?>
        ..['ts'] = -5;
      expect(RelayEnvelope.tryDecode(jsonEncode(negative)), isNull);
    });
  });
}
