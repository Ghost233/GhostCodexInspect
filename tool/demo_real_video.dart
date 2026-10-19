// 真机视频流诊断（#79 排查：用户反馈 h264/h265 均无法显示）。
//
// 前置：ChatGPT.app 已带 --remote-debugging-port=9238 运行。
//
// 用法：dart run tool/demo_real_video.dart [--codec=h264|hevc]
//
// 行为：attach 9238（不动目标）→ 主 shell → 中转 + VideoSession →
// headless Chrome 打开远程端切视频流模式 → 诊断 WebCodecs 解码状态
// （framesDecoded / has-frame / lastError / 解码器配置支持矩阵）→ 结论。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';
import 'package:ghost_codex_inspect/launcher/target_profile.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const debugPort = 9238;
const chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main(List<String> args) async {
  final codecArg = args
      .firstWhere((a) => a.startsWith('--codec='), orElse: () => '--codec=h264')
      .split('=')
      .last;
  final codec = VideoCodecKind.fromWireTag(codecArg);

  if (!await AppLauncher().isDebugPortAlive(debugPort)) {
    stderr.writeln('127.0.0.1:$debugPort 没有 CDP 端点，先带参启动目标。');
    exitCode = 2;
    return;
  }

  final relay = RelayServer(staticDir: 'assets/web');
  pp.Browser? browser;
  VideoSession? session;
  CdpConnection? connection;
  try {
    step('1/4 attach 真机主 shell（codec=$codecArg）');
    connection = await connectCdp(debugPort: debugPort);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(
      targets,
      TargetProfile.chatGpt.shellUrlSchemes,
    );
    stdout.writeln('主 shell：${shell.url}');
    final page = await connection.client.attachTo(shell);

    step('2/4 中转 + VideoSession');
    await relay.start();
    stdout.writeln('远程端：${relay.accessUrl}');
    session = VideoSession(page: page, relay: relay, codec: codec);
    await session.start();

    step('3/4 headless Chrome 打开远程端切视频流模式');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
    );
    final remote = await browser.newPage();
    await remote.goto('${relay.accessUrl}', wait: pp.Until.load);
    // 模式不再手选：首个 videoMeta 到达即自动切到视频窗格（2026-10-19）

    // 20s 内等待解码出帧；期间宿主侧有无观众也应已启动编码。
    var decoded = false;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final v = await remote.evaluate('''
        (() => {
          const vv = window.__remote && window.__remote.videoView;
          if (!vv) return {ready: false};
          return {
            ready: true,
            framesDecoded: vv.framesDecoded,
            codec: vv.codec,
            hasFrame: document.getElementById('video-canvas') &&
                document.getElementById('video-canvas')
                    .classList.contains('has-frame'),
            viewportW: vv.viewportWidth,
            viewportH: vv.viewportHeight,
          };
        })()
      ''');
      stdout.writeln('  … $v');
      if (v is Map && v['ready'] == true && (v['framesDecoded'] as num) > 3) {
        decoded = true;
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    step('4/4 诊断汇总');
    final diag = await remote.evaluate('''
      (async () => {
        const out = {};
        // 解码能力矩阵（真实 headless Chrome 环境）
        try {
          const m = await import('./js/video.js');
          out.support = await m.probeDecodeSupport();
        } catch (e) { out.supportError = String(e); }
        const vv = window.__remote && window.__remote.videoView;
        if (vv) {
          out.videoView = {
            framesDecoded: vv.framesDecoded,
            codec: vv.codec,
            viewport: [vv.viewportWidth, vv.viewportHeight],
          };
        }
        const banner = document.getElementById('error-banner');
        out.errorBanner = banner && !banner.classList.contains('hidden')
            ? banner.textContent : null;
        return out;
      })()
    ''');
    stdout.writeln('远程端诊断：$diag');
    final status = session.status;
    stdout.writeln(
      '宿主 VideoSession：encoding=${status.encoding} viewers=${status.viewers} '
      'framesEncoded=${status.framesEncoded} ausSent=${status.ausSent} '
      'bytesSent=${status.bytesSent} lastError=${status.lastError}',
    );
    stdout.writeln(decoded ? '\n✅ 视频解码出帧正常' : '\n❌ 未解码出帧');
    if (!decoded) exitCode = 1;
  } on Object catch (e) {
    stderr.writeln('诊断失败：$e');
    exitCode = 1;
  } finally {
    await session?.stop();
    await relay.stop();
    await browser?.close();
    await connection?.client.close();
  }
}
