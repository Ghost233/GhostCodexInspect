// 隔离验证 FfmpegVideoEncoder 在 nominalFps 与实际到达率不同组合下的
// 出帧行为（2026-10-19）。背景：全栈 E2E 中 fps=15/30 切换后 CDP 帧持续
// 喂入编码器（framesEncoded 增长）但 AU 产出冻结；fps=60 正常。本探针
// 用真实 screencast JPEG 帧 + 重绘泵，直接驱动 FfmpegVideoEncoder，
// 对比 (nth, nominalFps) = (1,60) / (2,30) / (4,15) 三种组合。
//
// 用法：`dart run tool/probe_encoder_fps.dart`
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/video/video.dart';

const int debugPort = 9240;
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
  stderr.writeln('[probe-enc] 启动 fixture…');
  await launcher.launch(profile, debugPort: debugPort);

  CdpConnection? connection;
  try {
    connection = await connectCdp(debugPort: debugPort, preferRaw: false);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['file']);
    final page = await connection.client.attachTo(shell);
    await page.send('Page.enable');
    await page.send('Emulation.setFocusEmulationEnabled', {'enabled': true});
    await page.send('Runtime.evaluate', {
      'expression': '''
        window.__pumpProbe = setInterval(() => {
          const el = document.getElementById('counter-label');
          if (el) el.textContent = 'pump ' + Date.now() % 100000;
        }, 50);
      ''',
    });

    for (final (nth, fps) in [(1, 60), (2, 30), (4, 15)]) {
      final encoder = FfmpegVideoEncoder(
        ffmpegPath: (await const FfmpegLocator().find()).path!,
        nominalFps: fps,
        bitrateKbps: 2000,
      );
      var fed = 0;
      var aus = 0;
      final auSub = encoder.accessUnits.listen((_) => aus++);
      final frameSub = page.screencastFrames.listen((frame) {
        page.send('Page.screencastFrameAck', {'sessionId': frame.sessionId});
        encoder.writeFrame(base64Decode(frame.data));
        fed++;
      });
      await encoder.start();
      await page.send('Page.startScreencast', {
        'format': 'jpeg',
        'quality': 90,
        'everyNthFrame': nth,
      });
      await Future<void>.delayed(const Duration(seconds: 6));
      await page.send('Page.stopScreencast');
      await frameSub.cancel();
      await auSub.cancel();
      await encoder.stop();
      stderr.writeln(
        '[probe-enc] nth=$nth nominalFps=$fps → 6s 喂入=$fed 出AU=$aus'
        '${aus == 0 ? '（编码器冻结）' : ''}',
      );
      await encoder.dispose();
    }
    await page.send('Runtime.evaluate', {
      'expression': 'clearInterval(window.__pumpProbe)',
    });
  } finally {
    await connection?.client.close();
    await launcher.stop(profile);
  }
}
