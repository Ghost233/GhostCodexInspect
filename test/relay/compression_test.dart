// 信封 payload 压缩单元测试（#14）：阈值行为、往返还原、损坏包装。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/relay/compression.dart';

void main() {
  group('maybeCompressPayload / maybeDecompressPayload', () {
    test('小于阈值原样透传', () {
      final small = {'type': 4, 'data': {'width': 720}};
      expect(maybeCompressPayload(small), same(small));
      expect(maybeDecompressPayload(small), same(small));
    });

    test('大于阈值压缩为 {z,b64} 包装并可还原', () {
      final big = {
        'type': 2,
        'data': {'payload': '快照内容' * 2000},
      };
      final wrapped = maybeCompressPayload(big);
      expect(isCompressedPayload(wrapped), isTrue);
      final map = wrapped! as Map;
      expect(map[kCompressionMarkerField], kCompressionAlgorithm);
      expect(map[kCompressionPayloadField], isA<String>());
      // 压缩确实变小了
      expect(
        (map[kCompressionPayloadField] as String).length,
        lessThan(utf8.encode(jsonEncode(big)).length),
      );
      expect(maybeDecompressPayload(wrapped), big);
    });

    test('minBytes: 0 时任何 payload 都压缩', () {
      final tiny = {'a': 1};
      final wrapped = maybeCompressPayload(tiny, minBytes: 0);
      expect(isCompressedPayload(wrapped), isTrue);
      expect(maybeDecompressPayload(wrapped), tiny);
    });

    test('数组 payload（batch）往返', () {
      final batch = List.generate(200, (i) => {'type': 3, 'i': i, 'pad': 'x' * 50});
      final wrapped = maybeCompressPayload(batch, minBytes: 0);
      expect(maybeDecompressPayload(wrapped), batch);
    });

    test('null 原样透传', () {
      expect(maybeCompressPayload(null), isNull);
      expect(maybeDecompressPayload(null), isNull);
    });

    test('损坏包装抛 FormatException', () {
      expect(
        () => maybeDecompressPayload({'z': 'fflate', 'b64': '!!!not-base64!!!'}),
        throwsFormatException,
      );
      expect(
        () => maybeDecompressPayload({'z': 'fflate'}),
        throwsFormatException,
      );
    });

    test('非压缩 Map 不受影响', () {
      final plain = {'z': 'other', 'b64': 'x'};
      expect(maybeDecompressPayload(plain), same(plain));
    });
  });
}
