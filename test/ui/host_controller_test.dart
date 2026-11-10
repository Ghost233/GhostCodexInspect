/// HostController 编排层单元测试（工单 #13）：互斥会话、中转生命周期、
/// 预览链接 ro=1。CDP 用替身客户端，中转用真实 RelayServer（回环端口 0）。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/ui/host_controller.dart';

class _FakeCdpPage implements CdpPage {
  @override
  final CdpTargetInfo target;

  _FakeCdpPage(this.target, {this.onNewWindow});

  final void Function()? onNewWindow;

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
    if (method == 'Runtime.evaluate' && onNewWindow != null) {
      onNewWindow!();
      return {
        'result': {'value': true},
      };
    }
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
      const Stream<Map<String, dynamic>>.empty();

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeCdpClient implements CdpClient {
  _FakeCdpPage? lastPage;
  bool closed = false;
  CdpTargetInfo? windowToCreate;

  @override
  String get implementationName => 'fake-cdp';

  @override
  Future<void> connect() async {}

  List<CdpTargetInfo> targets = const [
    CdpTargetInfo(
      id: 'shell-1',
      type: 'page',
      url: 'app://chatgpt.com/',
      title: 'ChatGPT',
    ),
    CdpTargetInfo(
      id: 'shell-2',
      type: 'page',
      url: 'app://chatgpt.com/detached-window.html?initialRoute=%2Fdetached',
      title: 'ChatGPT · 分离窗口',
    ),
    CdpTargetInfo(
      id: 'worker-1',
      type: 'service_worker',
      url: 'app://chatgpt.com/sw.js',
      title: 'sw',
    ),
  ];

  @override
  Future<List<CdpTargetInfo>> listTargets() async => targets;

  @override
  Future<CdpPage> attachTo(CdpTargetInfo target) async =>
      lastPage = _FakeCdpPage(
        target,
        onNewWindow: windowToCreate == null
            ? null
            : () => targets = [...targets, windowToCreate!],
      );

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late HostController controller;
  late _FakeCdpClient fakeClient;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'gci.relayAccessKey': 'saved-access-key',
    });
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
    expect(controller.accessUrls, isEmpty);
  });

  test('未配置密钥时不自动生成，须自行设置后才能启动中转', () async {
    SharedPreferences.setMockInitialValues({});
    await controller.loadSettings();
    expect(controller.hasRelayAccessKey, isFalse);
    await controller.startRelay();
    expect(controller.relayStatus.running, isFalse);
    expect(controller.lastError, contains('请先设置访问密钥'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('gci.relayAccessKey'), isFalse);
    await controller.setRelayAccessKey('custom-access-key');
    await controller.startRelay();
    expect(controller.lastError, isNull);
    expect(controller.relayStatus.running, isTrue);
    expect(controller.hasRelayAccessKey, isTrue);
  });

  test('中转未运行时启动会话：lastError 记录且不崩溃', () async {
    await controller.startSession(SessionKind.dom);
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

  test('DOM 会话：启动/互斥/停止（假 CDP + 真中转）', () async {
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.lastError, isNull);
    expect(controller.sessionKind, SessionKind.dom);
    expect(controller.cdpImplementationName, 'fake-cdp');
    // 启动序列：exposeBinding → Page.enable → 注入脚本
    expect(fakeClient.lastPage!.sentMethods, contains('Page.enable'));

    // 互斥：会话运行中再启另一个 → lastError 记录，会话不切换
    await controller.startSession(SessionKind.dom);
    expect(controller.sessionKind, SessionKind.dom);
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
    expect(controller.relayStatus.address, '0.0.0.0');
    expect(controller.previewUrl!.host, '127.0.0.1');
    // 重启换令牌：访问地址整体变化
    expect(controller.accessUrl.toString(), isNot(before));
  });

  test('访问密钥与固定 token 持久化，跨控制器重启保留且可手动轮转', () async {
    await controller.loadSettings();
    expect(controller.hasRelayAccessKey, isTrue);
    await controller.startRelay();
    final token = controller.relayToken;
    await controller.setFixedRelayToken(true);
    await controller.stopRelay();
    await controller.startRelay();
    expect(controller.relayToken, token);

    final restored = HostController(autoRefresh: false);
    addTearDown(restored.dispose);
    await restored.loadSettings();
    expect(restored.hasRelayAccessKey, isTrue);
    expect(restored.useFixedRelayToken, isTrue);
    expect(restored.relayToken, token);
    await restored.rotateRelayToken();
    expect(restored.relayToken, isNot(token));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('gci.fixedRelayToken'), restored.relayToken);

    await controller.rotateRelayToken();
    expect(controller.relayToken, isNot(token));
    final rotated = controller.relayToken;
    await controller.stopRelay();
    await controller.startRelay();
    expect(controller.relayToken, rotated);
    await controller.setFixedRelayToken(false);
    expect(controller.useFixedRelayToken, isFalse);
    expect(prefs.containsKey('gci.fixedRelayToken'), isFalse);
    expect(controller.relayToken, isNot(rotated));
    expect(controller.lastError, isNull);
  });

  test('自行设置密钥后持久化，短密钥被拒绝', () async {
    await controller.loadSettings();
    final prefs = await SharedPreferences.getInstance();
    final original = prefs.getString('gci.relayAccessKey');
    await controller.setRelayAccessKey('short');
    expect(prefs.getString('gci.relayAccessKey'), original);
    expect(controller.lastError, contains('至少 8 个字符'));
    await controller.setRelayAccessKey('custom-access-key');
    expect(controller.lastError, isNull);
    expect(prefs.getString('gci.relayAccessKey'), 'custom-access-key');
  });

  test('会话枚举 shell 清单并接管主窗口（#16）', () async {
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.lastError, isNull);
    expect(controller.shellTargets.map((t) => t.id), ['shell-1']);
    // 默认接管主窗口（无 initialRoute 的 shell）
    expect(controller.activeShellTargetId, 'shell-1');
    expect(fakeClient.lastPage!.target.id, 'shell-1');
  });

  test('单个主窗口不会把分离窗口和头像浮层页面广播为额外页签', () async {
    fakeClient.targets = [
      ...fakeClient.targets,
      const CdpTargetInfo(
        id: 'avatar',
        type: 'page',
        url: 'app://-/index.html?initialRoute=%2Favatar-overlay',
        title: 'ChatGPT',
      ),
    ];
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.lastError, isNull);
    expect(controller.shellTargets.map((t) => t.id), ['shell-1']);
    expect(controller.activeShellTargetId, 'shell-1');
    for (final id in ['avatar', 'shell-2']) {
      await controller.switchTarget(id);
      expect(controller.lastError, contains('不是 shell 页面'));
      expect(controller.activeShellTargetId, 'shell-1');
      expect(fakeClient.lastPage!.closed, isFalse);
    }
  });

  test('switchTarget：停旧会话并以相同模式接管新 shell（#16）', () async {
    fakeClient.targets = [
      fakeClient.targets.first,
      const CdpTargetInfo(
        id: 'shell-2',
        type: 'page',
        url: 'app://-/index.html',
        title: '另一个主窗口',
      ),
      fakeClient.targets.last,
    ];
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.activeShellTargetId, 'shell-1');

    await controller.switchTarget('shell-2');
    expect(controller.lastError, isNull);
    // 会话保持 DOM 模式，目标换成 shell-2
    expect(controller.sessionKind, SessionKind.dom);
    expect(controller.activeShellTargetId, 'shell-2');
    expect(fakeClient.lastPage!.target.id, 'shell-2');

    // 当前目标 / 不存在目标 / 无会话场景均为安全 no-op 或报错
    await controller.switchTarget('shell-2');
    expect(controller.activeShellTargetId, 'shell-2');
    await controller.switchTarget('worker-1');
    expect(controller.lastError, contains('不是 shell 页面'));
    expect(controller.activeShellTargetId, 'shell-2');

    await controller.stopSession();
    expect(controller.shellTargets, isEmpty);
    expect(controller.activeShellTargetId, isNull);
    await controller.switchTarget('shell-1'); // 无会话 no-op，不崩溃
  });

  test('新建远程专用窗口后仅接管新窗口，停止重连仍保留绑定', () async {
    const remote = CdpTargetInfo(
      id: 'remote-1',
      type: 'page',
      url: 'app://-/index.html',
      title: 'ChatGPT',
    );
    fakeClient.windowToCreate = remote;
    await controller.createRemoteWindow();
    expect(controller.lastError, isNull);
    expect(controller.remoteWindowCount, 1);
    expect(fakeClient.lastPage!.sentMethods, contains('Page.bringToFront'));
    expect(fakeClient.lastPage!.closed, isTrue);
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.activeShellTargetId, remote.id);
    expect(controller.shellTargets.map((t) => t.id), [remote.id]);
    await controller.switchTarget('shell-1');
    expect(controller.lastError, contains('不是 shell 页面'));
    expect(controller.activeShellTargetId, remote.id);
    await controller.stopSession();
    await controller.startSession(SessionKind.dom);
    expect(controller.activeShellTargetId, remote.id);
    expect(controller.lastError, isNull);
  });

  test('专用窗口关闭后启动失败，不会自动接管本机主窗口', () async {
    fakeClient.windowToCreate = const CdpTargetInfo(
      id: 'remote-closed',
      type: 'page',
      url: 'app://-/index.html',
      title: 'ChatGPT',
    );
    await controller.createRemoteWindow();
    fakeClient.targets = fakeClient.targets
        .where((t) => t.id != 'remote-closed')
        .toList();
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.lastError, contains('不会切回本机主窗口'));
    expect(controller.sessionKind, SessionKind.none);
    expect(controller.activeShellTargetId, isNull);
  });

  test('宿主重启后恢复专用窗口绑定，不重新选择本机主窗口', () async {
    fakeClient.windowToCreate = const CdpTargetInfo(
      id: 'remote-saved',
      type: 'page',
      url: 'app://-/index.html',
      title: 'ChatGPT',
    );
    await controller.createRemoteWindow();
    final restored = HostController(
      autoRefresh: false,
      cdpConnector: ({required int debugPort}) async =>
          CdpConnection(client: fakeClient, fellBack: false),
    );
    addTearDown(restored.dispose);
    await restored.loadSettings();
    expect(restored.remoteWindowCount, 1);
    await restored.startRelay();
    await restored.startSession(SessionKind.dom);
    expect(restored.lastError, isNull);
    expect(restored.activeShellTargetId, 'remote-saved');
  });

  test('多个专用窗口默认使用最新窗口，只允许在专用窗口之间切换', () async {
    for (final id in ['remote-1', 'remote-2']) {
      fakeClient.windowToCreate = CdpTargetInfo(
        id: id,
        type: 'page',
        url: 'app://-/index.html',
        title: 'ChatGPT',
      );
      await controller.createRemoteWindow();
      expect(controller.lastError, isNull);
    }
    expect(controller.remoteWindowCount, 2);
    await controller.startRelay();
    await controller.startSession(SessionKind.dom);
    expect(controller.activeShellTargetId, 'remote-2');
    expect(controller.shellTargets.map((t) => t.id), ['remote-1', 'remote-2']);
    await controller.switchTarget('remote-1');
    expect(controller.lastError, isNull);
    expect(controller.activeShellTargetId, 'remote-1');
  });

  test('客户端不支持新建窗口时明确失败，不建立专用窗口绑定', () async {
    await controller.createRemoteWindow();
    expect(controller.lastError, contains('新建远程窗口失败'));
    expect(controller.remoteWindowCount, 0);
    expect(fakeClient.lastPage!.closed, isTrue);
  });

  group('调试端口设置（#26）', () {
    test('默认取 profile.defaultDebugPort', () {
      final c = HostController(autoRefresh: false);
      addTearDown(c.dispose);
      expect(c.debugPort, TargetProfile.chatGpt.defaultDebugPort);
    });

    test('setDebugPort 校验范围并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final c = HostController(autoRefresh: false);
      addTearDown(c.dispose);
      await c.setDebugPort(9300);
      expect(c.debugPort, 9300);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gci.debugPort'), 9300);
      expect(() => c.setDebugPort(80), throwsArgumentError);
      expect(() => c.setDebugPort(70000), throwsArgumentError);
    });

    test('中转端口：默认随机(0)，可固定并持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final c = HostController(autoRefresh: false);
      addTearDown(c.dispose);
      expect(c.relayPort, 0);
      await c.setRelayPort(9410);
      expect(c.relayPort, 9410);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('gci.relayPort'), 9410);
      expect(() => c.setRelayPort(80), throwsArgumentError);
      await c.setRelayPort(0);
      expect(c.relayPort, 0);

      SharedPreferences.setMockInitialValues({'gci.relayPort': 9411});
      final c2 = HostController(autoRefresh: false);
      addTearDown(c2.dispose);
      await c2.loadSettings();
      expect(c2.relayPort, 9411);
    });

    test('loadSettings 读取持久化端口，非法值回落默认', () async {
      SharedPreferences.setMockInitialValues({'gci.debugPort': 9301});
      final c = HostController(autoRefresh: false);
      addTearDown(c.dispose);
      await c.loadSettings();
      expect(c.debugPort, 9301);

      SharedPreferences.setMockInitialValues({'gci.debugPort': 80});
      final c2 = HostController(autoRefresh: false);
      addTearDown(c2.dispose);
      await c2.loadSettings();
      expect(c2.debugPort, TargetProfile.chatGpt.defaultDebugPort);
    });
  });
}
