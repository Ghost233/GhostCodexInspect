import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/dom/editable_regions.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';

import 'dom_session_test.dart' show FakeCdpPage;

class _Page extends FakeCdpPage {
  List<Map<String, num>> regions = [
    {'x': 10, 'y': 20, 'width': 100, 'height': 30},
  ];
  @override
  Future<Object?> evaluate(String expression) async => jsonEncode(regions);
}

class _Relay extends RelayServer {
  final messages = <Object?>[];
  final directed = <int>[];
  @override
  void broadcast(
    RelayChannel channel,
    RelayMessageType type,
    Object? data, {
    Uint8List? binaryPayload,
  }) {
    expect(type, RelayMessageType.inputTargets);
    messages.add(data);
  }

  @override
  void sendTo(
    int clientId,
    RelayChannel channel,
    RelayMessageType type,
    Object? data,
  ) {
    directed.add(clientId);
    messages.add(data);
  }
}

void main() {
  test('输入区域有变化才广播，晚加入可补种，停止后归还鉴权回调', () async {
    final page = _Page();
    final relay = _Relay();
    var authed = 0;
    void previous(int id) {
      authed++;
    }

    relay.onClientAuthed = previous;
    final tracker = EditableRegions(page, relay);
    addTearDown(tracker.stop);
    await tracker.start();
    expect(relay.messages, [page.regions]);
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(relay.messages.length, 1);
    page.regions = [];
    await Future<void>.delayed(const Duration(milliseconds: 550));
    expect(relay.messages.last, isEmpty);
    relay.onClientAuthed!(7);
    expect(authed, 1);
    expect(relay.directed, [7]);
    tracker.stop();
    expect(relay.onClientAuthed, previous);
  });
}
