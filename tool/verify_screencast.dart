// 画面流模式端到端验证脚本（工单 #12 验收）。
//
// 链路（全程只操作 fixture，绝不触碰真实目标应用 ChatGPT.app）：
//   fixture（Electron 替身）──Page.startScreencast──▶ 宿主 ScreencastSession
//     ▲                        （ack 流控）              │frame 通道（base64 帧）
//     │                                                ▼
//     └──── CDP Input trusted 输入 ◀── input 通道 ◀── 远程端 <img> 刷新
//
// 两个验收面：
// - Phase A：Dart WS 客户端直连中转，验证 meta/帧收发、动画期间帧率 ≥10fps、
//   input 通道点击回灌 fixture。
// - Phase B：真浏览器（headless Chrome + 系统 Chrome）打开远程端页面并切到
//   画面流模式，验证 <img> 出图、远端点击坐标回灌 fixture、远程打字。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/verify_screencast.dart
//
// 前置：tool/fixture 已 npm install electron；已安装 Google Chrome。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/inspector/inspector.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/screencast/screencast.dart';
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

  step('1/7 前提校验 + 带参启动 fixture（端口 $debugPort）');
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
    step('2/7 CDP attach + 定位 shell 页面');
    final connection = await connectCdp(debugPort: launch.debugPort);
    stdout.writeln('CDP 实现：${connection.implementationName}');
    final shell = findShellTarget(
        await connection.client.listTargets(), profile.shellUrlSchemes);
    final page = await connection.client.attachTo(shell);
    stdout.writeln('shell：$shell');

    step('3/7 启动中转 + ScreencastSession，等待首帧');
    await relay.start();
    stdout.writeln('远程端访问链接：${relay.accessUrl}');
    // everyNthFrame 显式 1：本 E2E 用 10fps 动画源测帧率下限，限帧会干扰断言；
    // 生产默认 4（#14，真机带宽实测结论）。
    final session = ScreencastSession(page: page, relay: relay, everyNthFrame: 1);
    await session.start();
    await session.firstFrame.timeout(const Duration(seconds: 15),
        onTimeout: () {
      throw TimeoutException('首帧 15s 未到达');
    });
    stdout.writeln('首帧已到达（startScreencast + 帧订阅正常）');

    step('4/7 Phase A：Dart WS 客户端收 meta + 动画期间测帧率');
    final client = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:${relay.port}/ws'));
    await client.ready;
    final incoming = StreamController<RelayEnvelope>.broadcast();
    client.stream
        .listen((e) => incoming.add(RelayEnvelope.decode(e as String)));
    client.sink.add(RelayEnvelope(
      channel: RelayChannel.ctrl,
      type: RelayMessageType.auth,
      seq: 0,
      ts: 0,
      data: {'token': relay.token},
    ).encode());

    // 晚到客户端补种：authOk 后应收 meta + 合成帧。
    final seeded = await incoming.stream
        .take(3)
        .toList()
        .timeout(const Duration(seconds: 10));
    final types = seeded.map((e) => (e.channel, e.type)).toList();
    stdout.writeln('补种信封：$types');
    if (!types.any((t) => t.$1 == RelayChannel.frame && t.$2 == RelayMessageType.meta)) {
      throw StateError('Phase A 失败：补种缺少 frame/meta');
    }
    if (!types.any((t) => t.$1 == RelayChannel.frame && t.$2 == RelayMessageType.frame)) {
      throw StateError('Phase A 失败：补种缺少合成帧');
    }
    final meta = seeded.firstWhere(
        (e) => e.channel == RelayChannel.frame && e.type == RelayMessageType.meta);
    final viewport =
        jsonDecode(meta.data as String) as Map<String, dynamic>;
    stdout.writeln('视口元信息：$viewport');

    // 动画 3s 测帧率：页面内容变化驱动 screencast 产帧。
    await page.evaluate('''
      window.__gciAnim = setInterval(() => {
        document.body.style.filter =
          document.body.style.filter ? '' : 'invert(1)';
      }, 100);
      'anim-started'
    ''');
    var frameCount = 0;
    final counting = incoming.stream.listen((e) {
      if (e.channel == RelayChannel.frame && e.type == RelayMessageType.frame) {
        frameCount++;
      }
    });
    await Future<void>.delayed(const Duration(seconds: 3));
    await counting.cancel();
    await page.evaluate('clearInterval(window.__gciAnim); "anim-stopped"');
    final fps = frameCount / 3;
    stdout.writeln('动画 3s 内收到 $frameCount 帧（≈${fps.toStringAsFixed(1)}fps）');
    if (fps < 10) {
      throw StateError('Phase A 失败：帧率 ${fps.toStringAsFixed(1)}fps < 10fps 验收线');
    }

    step('5/7 Phase A：input 通道点击按钮回灌 fixture');
    final btnRect = jsonDecode(await page.evaluate(
            'JSON.stringify(document.getElementById("counter-btn").getBoundingClientRect())')
        as String) as Map<String, dynamic>;
    final btnX = (btnRect['left'] as num) + (btnRect['width'] as num) / 2;
    final btnY = (btnRect['top'] as num) + (btnRect['height'] as num) / 2;
    final titleBefore = await page.evaluate('document.title');
    var seq = 1;
    void sendInput(Object? data) {
      client.sink.add(RelayEnvelope(
        channel: RelayChannel.input,
        type: RelayMessageType.input,
        seq: seq++,
        ts: 0,
        data: data,
      ).encode());
    }

    sendInput({'kind': 'mouse', 'action': 'down', 'x': btnX, 'y': btnY});
    sendInput({'kind': 'mouse', 'action': 'up', 'x': btnX, 'y': btnY});
    await _pollEvaluate(
      page,
      'document.title',
      (v) => v != titleBefore,
      '远程点击后 fixture 标题应变化（$titleBefore → Fixture clicks=N）',
    );
    stdout.writeln('点击回灌成功：$titleBefore → ${await page.evaluate('document.title')}');
    await client.sink.close();

    step('6/7 Phase B：headless Chrome 打开远程端，切画面流模式出图');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--no-sandbox'],
    );
    final remote = await browser.newPage();
    remote.onConsole.listen((msg) => stdout.writeln('  [remote] ${msg.text}'));
    await remote.goto('${relay.accessUrl}', wait: pp.Until.domContentLoaded);
    await _pollEvaluate(
      remote.asCdpPageAdapter(),
      '!!(window.__remote && window.__remote.client)',
      (v) => v == true,
      '远程端脚本应初始化',
    );
    // 切到画面流模式（顶栏 tab），等待 <img> 出帧。
    await remote.click('#mode-screencast');
    await _pollEvaluate(
      remote.asCdpPageAdapter(),
      'document.querySelector("#screencast-img").classList.contains("has-frame")',
      (v) => v == true,
      '画面流 <img> 应收到帧（补种合成帧或实时帧）',
    );
    final imgState = await remote.evaluate('''
      (() => {
        const img = document.querySelector('#screencast-img');
        const r = img.getBoundingClientRect();
        const vp = window.__remote.screencastView.viewport;
        return { left: r.left, top: r.top, width: r.width,
                 naturalWidth: img.naturalWidth, viewport: vp };
      })()
    ''');
    stdout.writeln('远程端 img 状态：$imgState');
    if ((imgState as Map)['naturalWidth'] == 0) {
      throw StateError('Phase B 失败：img naturalWidth=0（JPEG 解码失败）');
    }

    step('7/7 Phase B：远端点击画面 + 打字回灌 fixture');
    // 源 CSS px → 远端显示坐标：rect.left + x * (img.clientWidth / viewportWidth)
    final vw = (imgState['viewport'] as Map)['viewportWidth'] as num;
    final scale = (imgState['width'] as num) / vw;
    final clickX = (imgState['left'] as num) + btnX * scale;
    final clickY = (imgState['top'] as num) + btnY * scale;
    final titleBeforeB = await page.evaluate('document.title');
    final inputsBefore = session.status().inputsDispatched;
    await remote.mouse.click(pp.Point(clickX, clickY));
    try {
      await _pollEvaluate(
        page,
        'document.title',
        (v) => v != titleBeforeB,
        '远端画面点击后 fixture 标题应变化',
        timeout: const Duration(seconds: 5),
      );
    } catch (e) {
      // 诊断：输入是否到达宿主？远端 _toSource 是否放行？
      final inputsAfter = session.status().inputsDispatched;
      final probe = await remote.evaluate('''
        (() => {
          const v = window.__remote.screencastView;
          const img = document.querySelector('#screencast-img');
          const r = img.getBoundingClientRect();
          const el = document.elementFromPoint($clickX, $clickY);
          return { inputsBefore: $inputsBefore, inputsAfter: $inputsAfter,
                   imgRect: {left: r.left, top: r.top, w: r.width, h: r.height},
                   hitElement: el ? el.id || el.className || el.tagName : null,
                   viewport: v.viewport, inner: [innerWidth, innerHeight] };
        })()
      ''');
      stdout.writeln('点击诊断：$probe');
      rethrow;
    }
    stdout.writeln('远端画面点击成功：${await page.evaluate('document.title')}');

    // 打字：点中输入框 → host 容器获得焦点 → keydown 转发。
    final inputRect = jsonDecode(await page.evaluate(
            'JSON.stringify(document.getElementById("echo-input").getBoundingClientRect())')
        as String) as Map<String, dynamic>;
    final inputX = (imgState['left'] as num) +
        ((inputRect['left'] as num) + (inputRect['width'] as num) / 2) * scale;
    final inputY = (imgState['top'] as num) +
        ((inputRect['top'] as num) + (inputRect['height'] as num) / 2) * scale;
    await remote.mouse.click(pp.Point(inputX, inputY));
    await remote.keyboard.type('ok');
    await _pollEvaluate(
      page,
      'document.getElementById("echo-input").value',
      (v) => v is String && v.contains('ok'),
      '远程打字后 echo-input 应包含 ok',
    );
    stdout.writeln('远程打字成功：echo-input=${await page.evaluate(
        'document.getElementById("echo-input").value')}');

    final status = session.status();
    stdout.writeln('\n画面流会话状态：frames=${status.framesSent} '
        'inputs=${status.inputsDispatched} lastError=${status.lastError}');
    stdout.writeln('\n=== 全部断言通过：画面流模式端到端链路 OK');
  } catch (e) {
    failed = true;
    stderr.writeln('\n!!! 验证失败：$e');
  } finally {
    await browser?.close();
    await relay.stop();
    await launcher.stop(profile);
  }
  if (failed) exitCode = 1;
}

/// 轮询 evaluate 直到断言成立。
Future<Object?> _pollEvaluate(
  dynamic page,
  String expression,
  bool Function(Object?) expect,
  String what, {
  Duration timeout = const Duration(seconds: 10),
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
    return result;
  }
}
