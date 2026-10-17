// GhostCodexInspect fixture 全链路验证脚本（工单 #10 验收）。
//
// 链路：检测 fixture app → 前提校验（标准 Electron，走通用判据）→
// 带参启动（--remote-debugging-port）→ CDP attach → target 枚举 →
// shell 过滤 → Runtime.evaluate 读回 document.title → 完整停止 fixture。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/verify_fixture_chain.dart
//
// 前置：tool/fixture 下已 npm install electron（见 tool/fixture/README.md）。
// 本脚本只操作 fixture，绝不触碰真实目标应用 ChatGPT.app。
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/inspector/inspector.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';

const debugPort = 9238;

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  final repoRoot = Directory.current.path;
  final fixtureDir = '$repoRoot/tool/fixture';
  final electronAppPath =
      '$fixtureDir/node_modules/electron/dist/Electron.app';

  if (!Directory(electronAppPath).existsSync()) {
    stderr.writeln(
      '未找到 fixture 的 Electron.app：$electronAppPath\n'
      '请先在 tool/fixture 下执行 npm install electron（见 README.md）。',
    );
    exitCode = 2;
    return;
  }

  final profile = TargetProfile.electronFixture(
    electronAppPath: electronAppPath,
    fixtureDir: fixtureDir,
  );
  final inspector = Inspector();
  final launcher = AppLauncher();

  step('1/5 目标检测与前提校验（fixture：标准 Electron，走通用判据）');
  final preflight = await inspector.checkPreflight(profile);
  stdout.writeln(preflight.toPrettyJson());
  if (!preflight.passed) {
    stderr.writeln('前提校验未通过，中止。');
    exitCode = 1;
    return;
  }

  step('2/5 带参启动 fixture（调试端口 $debugPort）');
  final launch = await launcher.launch(profile, debugPort: debugPort);
  stdout.writeln('已启动：pid=${launch.pid}，参数：${launch.args.join(' ')}');

  var failed = false;
  try {
    step('3/5 CDP attach（优先 puppeteer，失败回退 raw-websocket）');
    final connection = await connectCdp(debugPort: launch.debugPort);
    stdout.writeln(
      '生效实现：${connection.implementationName}'
      '${connection.fellBack ? '（回退，puppeteer 失败原因：${connection.puppeteerError}）' : ''}',
    );

    step('4/5 target 枚举与 shell 过滤（scheme：${profile.shellUrlSchemes.join(', ')}）');
    final targets = await connection.client.listTargets();
    for (final target in targets) {
      stdout.writeln('  $target');
    }
    final shell = findShellTarget(targets, profile.shellUrlSchemes);
    stdout.writeln('shell 命中：$shell');

    step('5/5 Runtime.evaluate 读回 document.title');
    final page = await connection.client.attachTo(shell);
    final title = await page.evaluate('document.title');
    stdout.writeln('document.title = $title');
    if (title != 'GhostCodexInspect Fixture Shell') {
      stderr.writeln('标题不符合期望，链路验证失败。');
      failed = true;
    }

    // 顺带验证回退实现也可用（同一抽象接口）。
    step('附加：raw-websocket 回退实现自检');
    final rawConnection = await connectCdp(
      debugPort: launch.debugPort,
      preferRaw: true,
    );
    final rawTargets = await rawConnection.client.listTargets();
    final rawShell = findShellTarget(rawTargets, profile.shellUrlSchemes);
    final rawPage = await rawConnection.client.attachTo(rawShell);
    final rawTitle = await rawPage.evaluate('document.title');
    stdout.writeln(
      'raw-websocket：document.title = $rawTitle（实现：${rawConnection.implementationName}）',
    );
    await rawConnection.client.close();
    if (rawTitle != 'GhostCodexInspect Fixture Shell') {
      stderr.writeln('回退实现标题不符合期望。');
      failed = true;
    }

    await connection.client.close();
  } finally {
    step('清理：完全停止 fixture 进程');
    await launcher.stop(profile);
    final remaining = await launcher.findRunningPids(profile);
    stdout.writeln(remaining.isEmpty ? 'fixture 已完全退出。' : '仍有残留 pid：$remaining');
  }

  if (failed) {
    exitCode = 1;
    return;
  }
  stdout.writeln('\n全链路验证通过。');
}
