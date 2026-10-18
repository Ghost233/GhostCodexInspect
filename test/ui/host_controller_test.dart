/// HostController 编排层单元测试（工单 #13）：互斥会话、中转生命周期、
/// 预览链接 ro=1。CDP 用替身客户端，中转用真实 RelayServer（回环端口 0）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';

class _FakeCdpPage implements CdpPage {
  @override
  final CdpTargetInfo target;

  _FakeCdpPage(this.target);

  final sentMethods = <String>[];
  bool closed = false;

  @override
  Future<Object?> evaluate(String expression) async =>
      '{"viewportWidth":1280,"viewportHeight":800,"dpr":2}';

  @override
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    sentMethods.add(method);
    return <String, dynamic>{};
  }

  @override
  Future<Stream<String>> exposeBinding(String name) async =>
      const Stream<String>.empty();

  @override
  Stream<ScreencastFrameData> get screencastFrames =>
      const Stream<ScreencastFrameData>.empty();

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeCdpClient implements CdpClient {
  _FakeCdpPage? lastPage;
  bool closed = false;

  @override
  String get implementationName => 'fake-cdp';

  @override
  Future<void> connect() async {}

  @override
  Future<List<CdpTargetInfo>> listTargets() async => const [
    CdpTargetInfo(
      id: 'shell-1',
      type: 'page',
      url: 'app://chatgpt.com/',
      title: 'ChatGPT',
    ),
    CdpTargetInfo(
      id: 'worker-1',
      type: 'service_worker',
      url: 'app://chatgpt.com/sw.js',
      title: 'sw',
    ),
  ];

  @override
  Future<CdpPage> attachTo(CdpTargetInfo target) async =>
      lastPage = _FakeCdpPage(target);

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late HostController controller;
  late _FakeCdpClient fakeClient;

  setUp(() {
    fakeClient = _FakeCdpClient();
    controller = HostController(
      autoRefresh: false,
      cdpConnector: ({required int debugPort}) async =>
          CdpConnection(client: fakeClient, fellBack: false),
    );
  });

  tearDown(() async {
    await controller.dispose();
  });

  test('初始状态：无会话、中转未运行、目标未运行', () {
    expect(controller.sessionKind, SessionKind.none);
    expect(controller.relayStatus.running, isFalse);
    expect(controller.targetRunning, isFalse);
    expect(controller.busy, isFalse);
    expect(controller.accessUrl, isNull);
  });

  test('中转未运行时启动会话：lastError 记录且不崩溃', () async {
    await controller.startSession(SessionKind.screencast);
    expect(controller.sessionKind, SessionKind.none);
    expect(controller.lastError, contains('中转未运行'));
  });

  test('中转启动后：accessUrl 带 #t=、previewUrl 追加 ro=1', () async {
    await controller.startRelay();
    expect(controller.relayStatus.running, isTrue);
    expect(controller.lastError, isNull);
    final url = controller.accessUrl.toString();
    expect(url, contains('#t='));
    expect(url, contains('127.0.0.1'));
    final preview = controller.previewUrl.toString();
    expect(preview, contains('ro=1'));
    expect(preview, contains('#t='));
  });

  test('画面流会话：启动/互斥/停止（假 CDP + 真中转）', () async {
    await controller.startRelay();
    await controller.startSession(SessionKind.screencast);
    expect(controller.lastError, isNull);
    expect(controller.sessionKind, SessionKind.screencast);
    expect(controller.cdpImplementationName, 'fake-cdp');
    // 启动序列：Page.enable → startScreencast（meta 由 evaluate 提供）
    expect(fakeClient.lastPage!.sentMethods, contains('Page.enable'));
    expect(fakeClient.lastPage!.sentMethods, contains('Page.startScreencast'));

    // 互斥：会话运行中再启另一个 → lastError 记录，会话不切换
    await controller.startSession(SessionKind.dom);
    expect(controller.sessionKind, SessionKind.screencast);
    expect(controller.lastError, contains('互斥'));

    await controller.stopSession();
    expect(controller.sessionKind, SessionKind.none);
    expect(fakeClient.closed, isTrue);
  });

  test('运行中切换局域网开关：中转重启并换令牌', () async {
    await controller.startRelay();
    final before = controller.accessUrl.toString();
    await controller.setLanAccess(true);
    expect(controller.lastError, isNull);
    expect(controller.relayStatus.running, isTrue);
    expect(controller.allowLanAccess, isTrue);
    // 重启换令牌：访问地址整体变化
    expect(controller.accessUrl.toString(), isNot(before));
  });
}
