import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp_client.dart';
import 'package:ghost_codex_inspect/dom/input_dispatcher.dart';

/// 最小 CdpPage 假实现：记录 send 调用。
class FakeCdpPage extends CdpPage {
  final List<(String, Map<String, dynamic>?)> sent = [];

  @override
  CdpTargetInfo get target => const CdpTargetInfo(
        id: 't1',
        type: 'page',
        url: 'file:///fixture',
        title: 'fixture',
      );

  @override
  Future<Object?> evaluate(String expression) async => null;

  @override
  Future<Map<String, dynamic>> send(String method,
      [Map<String, dynamic>? params]) async {
    sent.add((method, params));
    return <String, dynamic>{};
  }

  @override
  Future<Stream<String>> exposeBinding(String name) async =>
      const Stream<String>.empty();

  @override
  Future<void> close() async {}
}

void main() {
  group('validateInputPayload', () {
    test('mouse/wheel/text/key 合法 payload 通过', () {
      expect(validateInputPayload({'kind': 'mouse', 'action': 'move', 'x': 1, 'y': 2}),
          isA<Map<String, dynamic>>());
      expect(validateInputPayload({'kind': 'wheel', 'x': 0, 'y': 0, 'deltaX': 0, 'deltaY': -120}),
          isA<Map<String, dynamic>>());
      expect(validateInputPayload({'kind': 'text', 'text': '你好'}), isA<Map>());
      expect(validateInputPayload({'kind': 'key', 'key': 'Enter'}), isA<Map>());
    });

    test('非法 payload 抛 InputPayloadException', () {
      expect(() => validateInputPayload(null), throwsA(isA<InputPayloadException>()));
      expect(() => validateInputPayload({'kind': 'unknown'}), throwsA(isA<InputPayloadException>()));
      expect(() => validateInputPayload({'kind': 'mouse', 'action': 'hover', 'x': 0, 'y': 0}),
          throwsA(isA<InputPayloadException>()));
      expect(() => validateInputPayload({'kind': 'mouse', 'action': 'move', 'x': '0', 'y': 0}),
          throwsA(isA<InputPayloadException>()));
      expect(() => validateInputPayload({'kind': 'key', 'key': 'F13'}),
          throwsA(isA<InputPayloadException>()));
      expect(() => validateInputPayload({'kind': 'text', 'text': 42}),
          throwsA(isA<InputPayloadException>()));
    });
  });

  group('dispatchInput', () {
    late FakeCdpPage page;

    setUp(() => page = FakeCdpPage());

    test('mouse down 映射为 Input.dispatchMouseEvent mousePressed', () async {
      await dispatchInput(page, validateInputPayload(
          {'kind': 'mouse', 'action': 'down', 'x': 10.5, 'y': 20, 'button': 'right', 'clickCount': 1}));
      expect(page.sent, hasLength(1));
      final (method, params) = page.sent.single;
      expect(method, 'Input.dispatchMouseEvent');
      expect(params!['type'], 'mousePressed');
      expect(params['x'], 10.5);
      expect(params['y'], 20.0);
      expect(params['button'], 'right');
      expect(params['clickCount'], 1);
    });

    test('mouse move 不带 button/clickCount', () async {
      await dispatchInput(page, validateInputPayload(
          {'kind': 'mouse', 'action': 'move', 'x': 1, 'y': 2}));
      final (_, params) = page.sent.single;
      expect(params!['type'], 'mouseMoved');
      expect(params.containsKey('button'), isFalse);
      expect(params.containsKey('clickCount'), isFalse);
    });

    test('wheel 映射为 mouseWheel 事件', () async {
      await dispatchInput(page, validateInputPayload(
          {'kind': 'wheel', 'x': 5, 'y': 6, 'deltaX': 0, 'deltaY': -120}));
      final (method, params) = page.sent.single;
      expect(method, 'Input.dispatchMouseEvent');
      expect(params!['type'], 'mouseWheel');
      expect(params['deltaY'], -120.0);
    });

    test('text 走 Input.insertText（trusted 路径）', () async {
      await dispatchInput(page, validateInputPayload({'kind': 'text', 'text': 'hello 你好'}));
      final (method, params) = page.sent.single;
      expect(method, 'Input.insertText');
      expect(params!['text'], 'hello 你好');
    });

    test('key Enter 发 rawKeyDown+keyUp 且带 text \\r', () async {
      await dispatchInput(page, validateInputPayload({'kind': 'key', 'key': 'Enter'}));
      expect(page.sent, hasLength(2));
      final (m1, p1) = page.sent[0];
      final (m2, p2) = page.sent[1];
      expect(m1, 'Input.dispatchKeyEvent');
      expect(m2, 'Input.dispatchKeyEvent');
      expect(p1!['type'], 'rawKeyDown');
      expect(p1['windowsVirtualKeyCode'], 13);
      expect(p1['text'], '\r');
      expect(p2!['type'], 'keyUp');
    });
  });
}
