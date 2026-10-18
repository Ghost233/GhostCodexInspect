// FileChooserGuard 单测（工单 #20）：启用拦截 → 首次事件释放+提示+解除 →
// 幂等 stop。FakeCdpPage 记录 send 调用、由测试推入 fileChooser 事件。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeCdpPage extends CdpPage {
  final chooserController = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <(String, Map<String, dynamic>?)>[];

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
  Stream<ScreencastFrameData> get screencastFrames =>
      const Stream<ScreencastFrameData>.empty();

  @override
  Stream<Map<String, dynamic>> get fileChooserOpened =>
      chooserController.stream;

  @override
  Future<void> close() async {}
}

void main() {
  late Directory staticDir;
  late RelayServer relay;
  late _FakeCdpPage page;
  late FileChooserGuard guard;

  setUp(() async {
    staticDir = await Directory.systemTemp.createTemp('gci-fc-test');
    await File('${staticDir.path}/index.html').writeAsString('<html></html>');
    relay = RelayServer(staticDir: staticDir.path);
    await relay.start();
    page = _FakeCdpPage();
    guard = FileChooserGuard(page: page, relay: relay);
  });

  tearDown(() async {
    await guard.stop();
    await relay.stop();
    await staticDir.delete(recursive: true);
  });

  test('start 启用拦截', () async {
    await guard.start();
    expect(guard.isArmed, isTrue);
    expect(
      page.sent.any(
        (s) =>
            s.$1 == 'Page.setInterceptFileChooserDialog' &&
            s.$2?['enabled'] == true,
      ),
      isTrue,
    );
  });

  test('首次事件：释放选择 + 广播提示 + 解除拦截', () async {
    await guard.start();
    // 等 listen 生效（broadcast 流首个订阅同步挂起，保险起见让出事件循环）
    await Future<void>.delayed(Duration.zero);

    // 起一个 WS 客户端收 ctrl/fileChooserHint
    final received = <RelayEnvelope>[];
    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/ws'),
    );
    await channel.ready;
    final sub = channel.stream.listen((raw) {
      final env = RelayEnvelope.tryDecode(raw as String);
      if (env != null) received.add(env);
    });
    channel.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': relay.token},
      ).encode(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    page.chooserController.add({
      'frameId': 'f1',
      'mode': 'selectSingle',
      'backendNodeId': 42,
    });
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(guard.isArmed, isFalse);
    expect(guard.releasedCount, 1);
    // 空文件列表释放
    expect(
      page.sent.any(
        (s) =>
            s.$1 == 'DOM.setFileInputFiles' &&
            (s.$2?['files'] as List?)?.isEmpty == true &&
            s.$2?['backendNodeId'] == 42,
      ),
      isTrue,
    );
    // 解除拦截
    expect(
      page.sent.any(
        (s) =>
            s.$1 == 'Page.setInterceptFileChooserDialog' &&
            s.$2?['enabled'] == false,
      ),
      isTrue,
    );
    // 远程端收到提示
    expect(
      received.any(
        (e) =>
            e.channel == RelayChannel.ctrl &&
            e.type == RelayMessageType.fileChooserHint &&
            (e.data as Map)['message'] == kFileChooserHintMessage,
      ),
      isTrue,
    );
    await sub.cancel();
    await channel.sink.close();
  });

  test('解除后再次事件不重复释放', () async {
    await guard.start();
    await Future<void>.delayed(Duration.zero);
    page.chooserController.add({'backendNodeId': 1});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    page.chooserController.add({'backendNodeId': 2});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(guard.releasedCount, 1);
  });

  test('stop 幂等且解除拦截', () async {
    await guard.start();
    await guard.stop();
    await guard.stop();
    expect(
      page.sent.where(
        (s) =>
            s.$1 == 'Page.setInterceptFileChooserDialog' &&
            s.$2?['enabled'] == false,
      ),
      hasLength(1),
    );
  });
}
