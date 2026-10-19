// Bug 1 测量探针：操作延迟回归的管线定位（2026-10-19）。
//
// 用法：`dart run tool/probe_pipeline_latency.dart [quality]`（默认 90）。
//
// 用户现场等效条件：远程舞台 ~2080x1216（对照用户真实视口 2056x1218），
// fixture 全屏持续动画制造最大截帧压力，跑 40s，每 2s 采样：
//   宿主侧：framesEncoded（喂入）vs ausSent（发出）→ encodeQueueDepth
//          （writeFrame 无背压时的积压显形）+ lastFrameLatencyMs
//          （CDP 采集时刻 → AU 广播的端到端宿主延迟）。
//   远程侧：framesDecoded、decoder.decodeQueueSize（WebCodecs 积压显形）。
// 任一队列持续增长即定位到积压点；与 q60 对照可隔离 bd9018e 的影响。
//
// 端口纪律：fixture 固定 9240，启动前预检。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const int debugPort = 9240;
const String chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void log(String msg) => stderr.writeln('[probe-latency] $msg');

Future<void> main(List<String> args) async {
  final quality = args.isNotEmpty ? int.parse(args[0]) : 90;
  final fixtureApp = Directory('tool/fixture').existsSync()
      ? 'tool/fixture'
      : '../tool/fixture';

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

  log('① 启动 fixture（端口 $debugPort），quality=$quality …');
  await launcher.launch(profile, debugPort: debugPort);

  CdpConnection? connection;
  final relay = RelayServer(staticDir: 'assets/web');
  VideoSession? session;
  pp.Browser? browser;

  try {
    connection = await connectCdp(debugPort: debugPort, preferRaw: false);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['file']);
    final page = await connection.client.attachTo(shell);
    log('   shell=${shell.url}');

    await relay.start();
    session = VideoSession(
      page: page,
      relay: relay,
      locator: const FfmpegLocator(),
      quality: quality,
    );
    await session.start();
    log('   encoder=${session.status.encoder}');

    // 全屏持续重绘：背景渐变 + 移动色块 + 计数器，制造最大截帧压力
    await page.evaluate('''
      (function __gciChurn(){
        if (!document.body) { setTimeout(__gciChurn, 50); return; }
        document.body.style.margin = '0';
        const box = document.createElement('div');
        box.id = '__churn';
        box.style.cssText = 'position:fixed;inset:0;z-index:99999;'
          + 'font:700 120px/1 monospace;color:#fff;display:flex;'
          + 'align-items:center;justify-content:center;';
        document.body.appendChild(box);
        let i = 0;
        (function tick(){
          i++;
          const hue = i % 360;
          box.style.background = 'linear-gradient(' + (i % 360) + 'deg,'
            + ' hsl(' + hue + ',80%,50%), hsl(' + ((hue+120)%360) + ',80%,40%))';
          box.textContent = String(i).padStart(6, '0');
          requestAnimationFrame(tick);
        })();
      })()
    ''');

    log('② 启动 headless Chrome 远程端（2080x1300，舞台约 2080x1216）…');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--window-size=2080,1300'],
    );
    final remote = await browser.newPage();
    await remote.goto('${relay.accessUrl}', wait: pp.Until.load);

    log('③ 等出帧 + 视口跟随落定…');
    final deadline0 = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline0)) {
      final n = await remote.evaluate(
        'window.__remote && window.__remote.videoView.framesDecoded || 0',
      );
      if ((n as num) > 3) break;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await Future<void>.delayed(const Duration(seconds: 2));

    log('④ 负载采样 40s（每 2s 一行）…');
    log('   t | 喂入 发出 管线深度 捕获延迟ms | 远端解码 解码队列 | 码率kbps');
    final t0 = DateTime.now();
    var lastBytes = 0;
    var lastT = t0;
    var maxDepth = 0;
    var maxLatency = 0.0;
    var maxDecodeQ = 0;
    for (var s = 0; s < 20; s++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final st = session.status;
      final rd = jsonDecode(
        await remote.evaluate('''
        JSON.stringify({
          dec: window.__remote.videoView.framesDecoded,
          q: window.__remote.videoView._decoder
            ? window.__remote.videoView._decoder.decodeQueueSize : -1,
          err: window.__remote.videoView.lastError,
        })
      ''') as String,
      ) as Map<String, dynamic>;
      final now = DateTime.now();
      final kbps =
          ((st.bytesSent - lastBytes) *
                  8 /
                  now.difference(lastT).inMilliseconds *
                  1000 /
                  1000)
              .toStringAsFixed(0);
      lastBytes = st.bytesSent;
      lastT = now;
      maxDepth = st.encodeQueueDepth > maxDepth
          ? st.encodeQueueDepth
          : maxDepth;
      maxLatency = st.lastFrameLatencyMs > maxLatency
          ? st.lastFrameLatencyMs
          : maxLatency;
      final dq = (rd['q'] as num).toInt();
      maxDecodeQ = dq > maxDecodeQ ? dq : maxDecodeQ;
      log(
        '   ${now.difference(t0).inSeconds}s | '
        '${st.framesEncoded} ${st.ausSent} ${st.encodeQueueDepth} '
        '${st.lastFrameLatencyMs.toStringAsFixed(0)} | '
        '${rd['dec']} $dq | $kbps',
      );
    }

    log(
      '⑤ 结论：quality=$quality 最大管线深度=$maxDepth '
      '最大捕获延迟=${maxLatency.toStringAsFixed(0)}ms '
      '最大远端解码队列=$maxDecodeQ',
    );
    if (maxDepth > 8 || maxLatency > 500 || maxDecodeQ > 8) {
      log('❌ 观测到积压/高延迟：回归复现');
      exitCode = 1;
    } else {
      log('✅ 全程无积压：此条件下未复现');
    }
  } finally {
    await browser?.close();
    await session?.stop();
    await relay.stop();
    await connection?.client.close();
    await launcher.stop(profile);
  }
}
