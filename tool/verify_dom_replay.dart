// DOM 重绘端到端验证脚本（工单 #11 验收）。
//
// 链路（全程只操作 fixture，绝不触碰真实目标应用 ChatGPT.app）：
//   fixture（Electron 替身）──rrweb 采集──▶ 宿主 DomSession ──dom 通道──▶ 中转
//     ▲                                                                   │
//     └────────── CDP Input trusted 输入 ◀── input 通道 ◀── 远程端 ◀──────┘
//
// 两个验收面：
// - Phase A：Dart WS 客户端直连中转，验证协议级收发（resync、点击、输入文本）。
// - Phase B：真浏览器（headless Chrome + 系统 Chrome）打开远程端页面，
//   验证 rrweb Replayer 真实重建画面，并经输入捕获层点击/打字回灌 fixture。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/verify_dom_replay.dart
//
// 前置：tool/fixture 已 npm install electron；已安装 Google Chrome。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/inspector/inspector.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:puppeteer/puppeteer.dart' as pp;
import 'package:web_socket_channel/web_socket_channel.dart';

// fixture 专用调试端口（工单 #14）：与真机 9238 分离，避免真机占端口时
// fixture 绑定静默失败、connectCdp 错连真机（2026-10-17 事故）。
const debugPort = 9240;
const chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  final repoRoot = Directory.current.path;
  final fixtureDir = '$repoRoot/tool/fixture';
  final electronAppPath = '$fixtureDir/node_modules/electron/dist/Electron.app';
  for (final (path, hint) in [
    (electronAppPath, '请先在 tool/fixture 下 npm install electron'),
    (chromePath, 'Phase B 需要系统 Chrome'),
  ]) {
    if (!File(path).existsSync() && !Directory(path).existsSync()) {
      stderr.writeln('未找到：$path（$hint）');
      exitCode = 2;
      return;
    }
  }

  final profile = TargetProfile.electronFixture(
    electronAppPath: electronAppPath,
    fixtureDir: fixtureDir,
  );
  final inspector = Inspector();
  final launcher = AppLauncher();

  // 端口预检（第二道防线）：端口已被占用时拒绝启动，宁可失败也不错连。
  if (await launcher.isDebugPortAlive(debugPort)) {
    stderr.writeln('端口 $debugPort 已有 CDP 端点（疑似真机或残留 fixture 实例），'
        '拒绝启动 fixture 以防错连；请先释放端口。');
    exitCode = 2;
    return;
  }

  step('1/8 前提校验 + 带参启动 fixture（端口 $debugPort）');
  final preflight = await inspector.checkPreflight(profile);
  if (!preflight.passed) {
    stderr.writeln('前提校验未通过：\n${preflight.toPrettyJson()}');
    exitCode = 1;
    return;
  }
  final launch = await launcher.launch(profile, debugPort: debugPort);
  stdout.writeln('fixture pid=${launch.pid}');

  final relay = RelayServer(staticDir: 'assets/web');
  pp.Browser? browser;
  var failed = false;
  try {
    step('2/8 CDP attach + 定位 shell 页面');
    final connection = await connectCdp(debugPort: launch.debugPort);
    stdout.writeln('CDP 实现：${connection.implementationName}');
    final shell =
        findShellTarget(await connection.client.listTargets(), profile.shellUrlSchemes);
    final page = await connection.client.attachTo(shell);
    stdout.writeln('shell：$shell');

    step('3/8 启动中转 + 建立 DomSession，等待首份全量快照');
    await relay.start();
    stdout.writeln('远程端访问链接：${relay.accessUrl}');
    // compressionMinBytes: 0（#14）：fixture 快照小于默认阈值不会走压缩路径，
    // 这里强制全压缩，让 Phase B 的 headless Chrome 实测远程端 fflate 解压链路。
    final session = DomSession(page: page, relay: relay, compressionMinBytes: 0);
    await session.start();
    await session.firstFullSnapshot
        .timeout(const Duration(seconds: 15), onTimeout: () {
      throw TimeoutException('首份全量快照 15s 未到达');
    });
    stdout.writeln('首份全量快照已到达（采集器注入与 binding 回传正常）');

    step('4/8 Phase A：Dart WS 客户端鉴权 + resync');
    final client = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${relay.port}/ws'));
    await client.ready;
    final incoming = StreamController<RelayEnvelope>.broadcast();
    client.stream.listen((e) => incoming.add(RelayEnvelope.decode(e as String)));
    var seq = 0;
    void send(RelayChannel ch, RelayMessageType t, Object? data) {
      client.sink.add(RelayEnvelope(
              channel: ch, type: t, seq: ++seq, ts: 0, data: data)
          .encode());
    }

    send(RelayChannel.ctrl, RelayMessageType.auth, {'token': relay.token});
    final authOk = await incoming.stream.first.timeout(const Duration(seconds: 5));
    if (authOk.type != RelayMessageType.authOk) {
      throw StateError('鉴权未通过：$authOk');
    }
    send(RelayChannel.ctrl, RelayMessageType.resync, const {});
    final gotFull = await incoming.stream
        .firstWhere((e) => e.type == RelayMessageType.full)
        .timeout(const Duration(seconds: 10));
    stdout.writeln('resync 后收到全量快照（${jsonEncode(gotFull.data).length} 字节 JSON）');

    step('5/8 Phase A：input 通道点击按钮 + 输入文本');
    final btnRect = jsonDecode((await page.evaluate(
            "JSON.stringify(document.getElementById('counter-btn').getBoundingClientRect())"))
        as String) as Map<String, dynamic>;
    final btnX = (btnRect['left'] as num) + (btnRect['width'] as num) / 2;
    final btnY = (btnRect['top'] as num) + (btnRect['height'] as num) / 2;
    send(RelayChannel.input, RelayMessageType.input,
        {'kind': 'mouse', 'action': 'down', 'x': btnX, 'y': btnY});
    send(RelayChannel.input, RelayMessageType.input,
        {'kind': 'mouse', 'action': 'up', 'x': btnX, 'y': btnY});
    // 读回标题断言点击生效（_pollEvaluate 轮询覆盖 CDP 往返延迟）
    final titleAfterClick = await _pollEvaluate(
        page, 'document.title', (v) => v == 'Fixture clicks=1',
        what: '按钮点击后标题应为 Fixture clicks=1');
    stdout.writeln('点击生效：document.title = $titleAfterClick');

    final inputRect = jsonDecode((await page.evaluate(
            "JSON.stringify(document.getElementById('echo-input').getBoundingClientRect())"))
        as String) as Map<String, dynamic>;
    final inX = (inputRect['left'] as num) + 5;
    final inY = (inputRect['top'] as num) + (inputRect['height'] as num) / 2;
    send(RelayChannel.input, RelayMessageType.input,
        {'kind': 'mouse', 'action': 'down', 'x': inX, 'y': inY});
    send(RelayChannel.input, RelayMessageType.input,
        {'kind': 'mouse', 'action': 'up', 'x': inX, 'y': inY});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    send(RelayChannel.input, RelayMessageType.input, {'kind': 'text', 'text': 'hi'});
    final echo = await _pollEvaluate(
        page, "document.getElementById('echo-label').textContent",
        (v) => v == 'hi',
        what: '输入文本应镜像到 #echo-label');
    stdout.writeln('文本输入生效：#echo-label = $echo');
    await incoming.close();
    await client.sink.close();

    step('6/8 raw 回退客户端 binding 自检（fallback 路径未被 DomSession 覆盖）');
    // DomSession 走的是 connectCdp 选出的 puppeteer 实现；这里单独建一条
    // RawCdpClient 连接，验证 Runtime.addBinding + bindingCalled 回传链路。
    final rawClient = RawCdpClient(debugPort: launch.debugPort);
    await rawClient.connect();
    try {
      final rawPage = await rawClient.attachTo(shell);
      final rawPayloads = await rawPage.exposeBinding('__gciRawProbe');
      final probeFuture =
          rawPayloads.first.timeout(const Duration(seconds: 10));
      await rawPage.evaluate("window.__gciRawProbe('raw-binding-probe')");
      final probePayload = await probeFuture;
      if (probePayload != 'raw-binding-probe') {
        throw StateError('raw binding 载荷不符：$probePayload');
      }
      stdout.writeln('raw 回退 binding 回传正常：$probePayload');
    } finally {
      await rawClient.close();
    }

    step('7/8 Phase B：headless Chrome 打开远程端，Replayer 真实重建');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--window-size=1024,768'],
    );
    final remotePage = await browser.newPage();
    await remotePage.goto('${relay.accessUrl}', wait: pp.Until.domContentLoaded);
    // 等 Replayer 挂载（鉴权 → full → startLive）
    await _pollEvaluate(
        remotePage.asCdpPageAdapter(),
        '!!(window.__remote && window.__remote.session && window.__remote.session.replayer)',
        (v) => v == true,
        what: '远程端 Replayer 应挂载');
    // 验收要求：replay iframe 里出现 fixture 页面内容文本。
    // @rrweb/replay 的 iframe 与宿主页同源（sandbox=allow-same-origin），可直接读。
    final iframeText = await _pollEvaluate(
        remotePage.asCdpPageAdapter(), '''
(() => {
  const iframe = document.querySelector('#replayer-host iframe');
  const doc = iframe && iframe.contentDocument;
  return doc && doc.body ? doc.body.innerText : '';
})()
''', (v) => v is String && v.contains('Electron 替身 fixture'),
        what: 'replay iframe 应包含 fixture 页面文本');
    stdout.writeln('replay iframe 内容文本断言通过（含「Electron 替身 fixture」，'
        '共 ${(iframeText as String).length} 字符）');

    step('8/8 Phase B：远程端点击 + 打字 → 回灌 fixture');
    // 按钮的远端显示坐标 = iframe 视觉原点 + 源坐标 × scale
    final clickPoint = await _pollEvaluate(remotePage.asCdpPageAdapter(), '''
(() => {
  const r = window.__remote.session;
  const iframe = document.querySelector('#replayer-host iframe');
  if (!r || !iframe || !r.scale) return null;
  const rect = iframe.getBoundingClientRect();
  return {x: rect.left + $btnX * r.scale, y: rect.top + $btnY * r.scale};
})()
''', (v) => v is Map && v['x'] != null, what: '应算出远端点击坐标');
    final point = clickPoint as Map;
    await remotePage.mouse.click(
        pp.Point((point['x'] as num).toDouble(), (point['y'] as num).toDouble()));
    final titleAfterRemoteClick = await _pollEvaluate(
        page, 'document.title', (v) => v == 'Fixture clicks=2',
        what: '远程端点击后标题应为 Fixture clicks=2');
    stdout.writeln('远程端点击回灌生效：document.title = $titleAfterRemoteClick');

    // 远程端文本输入：点击远端输入框位置 → 键盘逐字符（input.js 把可打印
    // 字符聚成 {kind:text} 逐字符即发）→ 宿主 insertText 写回 fixture。
    final inputPoint = await _pollEvaluate(remotePage.asCdpPageAdapter(), '''
(() => {
  const r = window.__remote.session;
  const iframe = document.querySelector('#replayer-host iframe');
  if (!r || !iframe || !r.scale) return null;
  const rect = iframe.getBoundingClientRect();
  return {x: rect.left + $inX * r.scale, y: rect.top + $inY * r.scale};
})()
''', (v) => v is Map && v['x'] != null, what: '应算出远端输入框点击坐标');
    final inPoint = inputPoint as Map;
    await remotePage.mouse.click(pp.Point(
        (inPoint['x'] as num).toDouble(), (inPoint['y'] as num).toDouble()));
    await remotePage.keyboard.type('ok');
    // 注意：点击落在输入框左缘，caret 在 0 位，插入结果是 'okhi' 而非
    // 'hiok'——只断言两段文本都在，不断言顺序。
    final fixtureInputValue = await _pollEvaluate(
        page, "document.getElementById('echo-input').value",
        (v) => v is String && v.contains('hi') && v.contains('ok'),
        what: '远程端输入后 fixture 输入框值应含 hi（Phase A）与 ok（Phase B）');
    stdout.writeln('远程端文本输入回灌生效：#echo-input.value = $fixtureInputValue');

    final status = session.status();
    stdout.writeln('DomSession 状态：batches=${status.batchesReceived} '
        'envelopes=${status.envelopesSent} inputs=${status.inputsDispatched} '
        'lastError=${status.lastError}');
    if (status.inputsDispatched < 7) {
      stderr.writeln('输入下发计数异常（预期 ≥7：A 两次点击(4)+一次文本(1)、'
          'B 一次点击(2)+两字符文本(2)）');
      failed = true;
    }

    await session.stop();
    await connection.client.close();
  } catch (e) {
    stderr.writeln('验证失败：$e');
    failed = true;
  } finally {
    await browser?.close();
    step('清理：停中转 + 完全退出 fixture');
    await relay.stop();
    await launcher.stop(profile);
  }

  if (failed) {
    exitCode = 1;
    return;
  }
  stdout.writeln('\nDOM 重绘端到端验证通过（Phase A 协议级 + Phase B 真浏览器）。');
}

/// 轮询 evaluate 直到返回值满足 [expect]（用于跨进程异步生效的断言）。
Future<Object?> _pollEvaluate(
  dynamic page,
  String expression,
  bool Function(Object?) expect, {
  required String what,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? value;
  do {
    try {
      value = await (page.evaluate(expression) as Future<Object?>);
    } catch (_) {
      value = null;
    }
    if (expect(value)) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } while (DateTime.now().isBefore(deadline));
  throw TimeoutException('断言超时：$what（最后值：$value）', timeout);
}

/// puppeteer Page → 薄适配（仅 evaluate，供 _pollEvaluate 复用）。
extension on pp.Page {
  _PuppeteerEvalOnly asCdpPageAdapter() => _PuppeteerEvalOnly(this);
}

class _PuppeteerEvalOnly {
  _PuppeteerEvalOnly(this._page);
  final pp.Page _page;
  Future<Object?> evaluate(String expression) async {
    final result = await _page.evaluate(expression);
    // puppeteer evaluate 返回 List/Map 之外的标量按原样；Map 来自 JsHandle 转值
    return result;
  }
}
