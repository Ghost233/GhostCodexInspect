// 真机端到端演示（DOM 重绘模式，只读、采集器注入约 30 秒即停）。
//
// 前置：ChatGPT.app（Codex）已带 --remote-debugging-port=9238 运行。
//
// 用法：
//   dart run tool/demo_real_dom.dart
//
// 行为：attach 已运行实例（绝不重启/关闭目标）→ 定位主 shell 页面 →
// 起中转 + DomSession（注入 rrweb 采集器）→ headless Chrome 以只读
// （ro=1）打开远程端 → 断言 Replayer 重建出 shell DOM → 采样 30 秒 →
// 打印结论并停止。
// 安全边界：只读预览（ro=1 禁用输入层，inputsDispatched 必须保持 0）；
// 采集器只挂在主 shell 页面（app:// 骨架层），跨域 webview（chatgpt.com
// 对话内容）看不到也碰不到；CDP 会话死亡后注入自动回收（已实测零残留）。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';
import 'package:ghost_codex_inspect/launcher/target_profile.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const debugPort = 9238;
const chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  step('1/5 确认真机调试端口在监听（attach 模式，不动目标进程）');
  if (!await AppLauncher().isDebugPortAlive(debugPort)) {
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
  DomSession? session;
  CdpConnection? connection;
  var failed = false;
  try {
    step('2/5 CDP attach + 定位主 shell 页面');
    connection = await connectCdp(debugPort: debugPort);
    stdout.writeln('CDP 实现：${connection.implementationName}');
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(
      targets,
      TargetProfile.chatGpt.shellUrlSchemes,
    );
    stdout.writeln('主 shell：${shell.url}（共 ${targets.length} 个 target）');
    final page = await connection.client.attachTo(shell);

    step('3/5 启动中转 + DomSession（注入采集器，等首份全量快照）');
    await relay.start();
    stdout.writeln('远程端访问链接（本机浏览器也可打开）：${relay.accessUrl}');
    session = DomSession(page: page, relay: relay);
    await session.start();
    await session.firstFullSnapshot.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        throw TimeoutException('首份全量快照 20s 未到达');
      },
    );
    stdout.writeln('首份全量快照已到达（采集器注入与 binding 回传正常）。');

    step('4/5 headless Chrome 只读打开远程端，断言 Replayer 重建');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
    );
    final remote = await browser.newPage();
    // 不能用 networkIdle：远程端页面加载后立即建立常连 WebSocket。
    await remote.goto('${relay.accessUrl}&ro=1', wait: pp.Until.load);
    final readOnly = await remote.evaluate(
      "!document.getElementById('ro-badge').classList.contains('hidden')",
    );
    if (readOnly != true) {
      throw StateError('ro=1 只读徽标未显示');
    }
    await _poll(
      remote,
      "(() => { const f = document.querySelector('.replayer-host iframe');"
          " return f && f.contentDocument && f.contentDocument.body"
          " && f.contentDocument.body.childElementCount > 0; })()",
      'Replayer iframe 重建出非空 DOM',
      const Duration(seconds: 20),
    );
    stdout.writeln('远程端已重建主 shell DOM（ro=1 只读）。');

    step('5/5 采样 30 秒后停止（采集器随即随会话回收）');
    final before = session.status();
    await Future<void>.delayed(const Duration(seconds: 30));
    final after = session.status();
    stdout.writeln(
      '30s 采样：envelopes ${before.envelopesSent} → '
      '${after.envelopesSent}（+${after.envelopesSent - before.envelopesSent}），'
      'batches=${after.batchesReceived}，'
      'inputs=${after.inputsDispatched}，lastError=${after.lastError}',
    );
    if (after.inputsDispatched != 0) {
      throw StateError('只读演示不应有任何输入下发');
    }
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
  stdout.writeln(
    '\n真机 DOM 重绘演示通过：远程端只读重建主 shell，'
    '目标应用未受影响（会话关闭后注入自动回收）。',
  );
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
