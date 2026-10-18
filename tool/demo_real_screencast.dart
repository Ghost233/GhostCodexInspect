// 真机端到端演示（画面流模式，只读、零注入）。
//
// 前置：ChatGPT.app（Codex）已带 --remote-debugging-port=9238 运行
// （tool/restart_target_debug.sh 那次启动之后端口一直有效）。
//
// 用法：
//   dart run tool/demo_real_screencast.dart
//
// 行为：attach 已运行实例（绝不重启/关闭目标）→ 定位主 shell 页面 →
// 起中转 + ScreencastSession（默认限帧 everyNthFrame=4）→ headless Chrome
// 以只读（ro=1）打开远程端页面并切到画面流模式 → 采样 5s 帧率 → 打印结论。
// 安全边界：只读预览（ro=1 禁用输入层）；不做任何 Runtime.evaluate 注入；
// 结束时仅停止 screencast 与中转，目标应用进程完全不动。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';
import 'package:ghost_codex_inspect/launcher/target_profile.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/screencast/screencast.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const debugPort = 9238;
const chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  step('1/5 确认真机调试端口在监听（attach 模式，不动目标进程）');
  final launcher = AppLauncher();
  if (!await launcher.isDebugPortAlive(debugPort)) {
    stderr.writeln(
      '127.0.0.1:$debugPort 没有 CDP 端点。'
      '请先双击「调试重启 ChatGPT（9238）.app」或运行 tool/restart_target_debug.sh。',
    );
    exitCode = 2;
    return;
  }
  stdout.writeln('端口 $debugPort 就绪。');

  final relay = RelayServer(staticDir: 'assets/web');
  pp.Browser? browser;
  ScreencastSession? session;
  CdpConnection? connection;
  var failed = false;
  try {
    step('2/5 CDP attach + 定位主 shell 页面');
    connection = await connectCdp(debugPort: debugPort);
    stdout.writeln('CDP 实现：${connection.implementationName}');
    final targets = await connection.client.listTargets();
    stdout.writeln('目标数：${targets.length}');
    final shell = findShellTarget(
      targets,
      TargetProfile.chatGpt.shellUrlSchemes,
    );
    stdout.writeln('主 shell：${shell.url}');
    final page = await connection.client.attachTo(shell);

    step('3/5 启动中转 + 画面流会话（quality=60, everyNthFrame=4 限帧）');
    await relay.start();
    stdout.writeln('远程端访问链接（本机浏览器也可打开）：${relay.accessUrl}');
    session = ScreencastSession(page: page, relay: relay);
    await session.start();
    await session.firstFrame.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        throw TimeoutException('首帧 15s 未到达');
      },
    );
    stdout.writeln('首帧已到达。');

    step('4/5 headless Chrome 只读打开远程端，切画面流模式，采样 5 秒');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
    );
    final remote = await browser.newPage();
    // 不能用 networkIdle：远程端页面加载后立即建立常连 WebSocket，
    // 网络永不空闲（30s 导航超时事故的根因）。
    await remote.goto('${relay.accessUrl}&ro=1', wait: pp.Until.load);
    final readOnly = await remote.evaluate(
      "!document.getElementById('ro-badge').classList.contains('hidden')",
    );
    if (readOnly != true) {
      throw StateError('ro=1 只读徽标未显示');
    }
    await remote.click('#mode-screencast');
    await _poll(
      remote,
      "document.querySelector('#screencast-img.has-frame') !== null",
      '远程端出图',
      const Duration(seconds: 10),
    );
    final before = session.status().framesSent;
    await Future<void>.delayed(const Duration(seconds: 5));
    final after = session.status().framesSent;
    final fps = (after - before) / 5;
    stdout.writeln(
      '采样 5s：$after - $before = ${after - before} 帧'
      '（${fps.toStringAsFixed(1)} fps）',
    );
    final status = session.status();
    stdout.writeln(
      '会话状态：frames=${status.framesSent} '
      'inputs=${status.inputsDispatched} lastError=${status.lastError}',
    );
    if (status.inputsDispatched != 0) {
      throw StateError('只读演示不应有任何输入下发');
    }
    if (after <= before) {
      throw StateError('5 秒内没有新帧（画面可能静止，属正常；如目标在动则无帧即为故障）');
    }

    step('5/5 清理（只停会话与中转，目标应用保持运行）');
  } on Object catch (e) {
    failed = true;
    stderr.writeln('\n演示失败：$e');
  } finally {
    await session?.stop();
    await relay.stop();
    await browser?.close();
    await connection?.client.close();
  }
  if (failed) {
    exitCode = 1;
    return;
  }
  stdout.writeln('\n真机画面流演示通过：远程端只读出图 + 帧流正常，目标应用未受影响。');
}

Future<void> _poll(
  pp.Page page,
  String expression,
  String label,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await page.evaluate(expression) == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw TimeoutException('$label：$timeout 内未满足');
}
