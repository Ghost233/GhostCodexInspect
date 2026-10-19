// 隔离验证 CDP Page.startScreencast 的 everyNthFrame 语义（2026-10-19）。
// 背景：真机目击远程端 15/30fps 在偶发时段几乎无帧、60fps 正常；全栈
// E2E（repro_viewport_follow Phase 3）在 15/30 下带重绘泵也收不到 AU。
// 本探针绕过 VideoSession/ffmpeg，直接对 fixture 页 startScreencast
// (everyNthFrame=N)，配合持续重绘泵统计 3s 到达帧数，判定「无帧」出在
// CDP 捕获层还是宿主编码层。
//
// 用法：`dart run tool/probe_every_nth_frame.dart`
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';

const int debugPort = 9240; // 与真机 9238 分离（事故教训）
const String fixtureApp = 'tool/fixture';

Future<void> main() async {
  final launcher = AppLauncher();
  if (await launcher.isDebugPortAlive(debugPort)) {
    stderr.writeln('端口 $debugPort 已被占用：请先关闭残留 fixture 进程');
    exitCode = 2;
    return;
  }
  final profile = TargetProfile.electronFixture(
    electronAppPath: '$fixtureApp/node_modules/electron/dist/Electron.app',
    fixtureDir: fixtureApp,
  );
  stderr.writeln('[probe] 启动 fixture…');
  await launcher.launch(profile, debugPort: debugPort);

  CdpConnection? connection;
  try {
    connection = await connectCdp(debugPort: debugPort, preferRaw: false);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['file']);
    final page = await connection.client.attachTo(shell);
    await page.send('Page.enable');
    await page.send('Emulation.setFocusEmulationEnabled', {'enabled': true});

    // 持续重绘泵：50ms 改可见文本（20Hz）
    await page.send('Runtime.evaluate', {
      'expression': '''
        window.__pumpProbe = setInterval(() => {
          const el = document.getElementById('counter-label');
          if (el) el.textContent = 'pump ' + Date.now() % 100000;
        }, 50);
      ''',
    });

    for (final nth in [1, 2, 4]) {
      var frames = 0;
      final sub = page.screencastFrames.listen((frame) {
        frames++;
        page.send('Page.screencastFrameAck', {'sessionId': frame.sessionId});
      });
      await page.send('Page.startScreencast', {
        'format': 'jpeg',
        'quality': 90,
        'everyNthFrame': nth,
      });
      await Future<void>.delayed(const Duration(seconds: 3));
      await page.send('Page.stopScreencast');
      await sub.cancel();
      stderr.writeln(
        '[probe] everyNthFrame=$nth → 3s 帧数=$frames'
        '（约 ${(frames / 3).toStringAsFixed(1)}fps）',
      );
    }
    await page.send('Runtime.evaluate', {
      'expression': 'clearInterval(window.__pumpProbe)',
    });
  } finally {
    await connection?.client.close();
    await launcher.stop(profile);
  }
}
