// Bug 2 复现：视口跟随 + 尺寸切换端到端（fixture 版，2026-10-19）。
//
// 用法：`dart run tool/repro_viewport_follow.dart`（需本机有 ffmpeg）。
//
// 复现目标：远程端首载后 Codex 页面视口应跟随远程舞台尺寸；中途改变
// 远程舞台尺寸 / 切换尺寸模式（fit→stretch→actual）应生效且视频流
// 不死。通过 WebSocket.send 打桩记录远程端每一次 setViewport 发送，
// 一层定位：远程没发 / 宿主没应用 / 编码器死。
//
// 端口纪律：fixture 固定 9240，启动前预检（9238 事故教训）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const int debugPort = 9240; // 与真机 9238 分离（2026-10-17 事故教训）
const String chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void log(String msg) => stderr.writeln('[repro-viewport] $msg');

Future<void> main() async {
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

  log('① 启动 fixture（端口 $debugPort）…');
  await launcher.launch(profile, debugPort: debugPort);

  CdpConnection? connection;
  final relay = RelayServer(staticDir: 'assets/web');
  VideoSession? session;
  pp.Browser? browser;
  var failures = 0;

  try {
    connection = await connectCdp(debugPort: debugPort, preferRaw: false);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['file']);
    final page = await connection.client.attachTo(shell);
    log('   shell=${shell.url}（${connection.implementationName}）');
    final initialVw = await page.evaluate('innerWidth');
    final initialVh = await page.evaluate('innerHeight');
    log('   fixture 初始视口 ${initialVw}x$initialVh');

    await relay.start();
    session = VideoSession(
      page: page,
      relay: relay,
      locator: const FfmpegLocator(),
    );
    await session.start();
    log('   encoder=${session.status.encoder} accessUrl=${relay.accessUrl}');

    // 画面要有变化才会出帧
    await page.evaluate(
      "(function __gciBlink(){ if (!document.body) { setTimeout(__gciBlink, 50); return; } setInterval(() => { document.body.style.filter = document.body.style.filter ? '' : 'invert(1)'; }, 100); })()",
    );

    log('② 启动 headless Chrome 远程端（1280x900）…');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--window-size=1280,900'],
    );
    final remote = await browser.newPage();
    // 打桩：记录远程端每一次 setViewport 发送（含首载竞态窗口内的）
    await remote.evaluateOnNewDocument('''
      (() => {
        const origSend = WebSocket.prototype.send;
        window.__svLog = [];
        WebSocket.prototype.send = function (data) {
          try {
            if (typeof data === 'string' && data.includes('setViewport')) {
              const env = JSON.parse(data);
              window.__svLog.push({
                w: env.data && env.data.width,
                h: env.data && env.data.height,
                t: Date.now(),
                readyState: this.readyState,
              });
            }
          } catch (_) {}
          return origSend.call(this, data);
        };
      })()
    ''');
    await remote.goto('${relay.accessUrl}', wait: pp.Until.load);

    // ---- Phase 0：首载视口跟随 ----
    log('③ Phase 0：等 WebCodecs 出帧 + 视口跟随落定…');
    await _waitTrue(
      remote,
      'window.__remote && window.__remote.videoView.framesDecoded > 3',
      'WebCodecs 出帧',
    );
    final settleOk = await _waitFixtureViewport(
      page,
      remote,
      const Duration(seconds: 15),
    );
    await _dumpState(page, remote, session, 'Phase 0 落定');
    if (!settleOk) {
      failures++;
      log('❌ Phase 0 FAIL：15s 内 fixture 视口未跟随远程舞台');
    } else {
      log('✅ Phase 0 PASS：fixture 视口已跟随远程舞台');
    }

    // ---- Phase 1：中途改远程舞台尺寸（奇数高 649 压测编码器） ----
    log('④ Phase 1：远程窗口改为 1000x701（舞台高约 649，奇数）…');
    await remote.setViewport(const pp.DeviceViewport(width: 1000, height: 701));
    final p1FramesBefore = await remote.evaluate(
      'window.__remote.videoView.framesDecoded',
    );
    final p1Ok = await _waitFixtureViewport(
      page,
      remote,
      const Duration(seconds: 15),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    final p1FramesAfter = await remote.evaluate(
      'window.__remote.videoView.framesDecoded',
    );
    await _dumpState(page, remote, session, 'Phase 1 落定');
    final streamAlive = (p1FramesAfter as num) > (p1FramesBefore as num);
    if (!p1Ok || !streamAlive) {
      failures++;
      log(
        '❌ Phase 1 FAIL：跟随=${p1Ok ? "✓" : "✗"} 流存活=${streamAlive ? "✓" : "✗"}'
        '（framesDecoded $p1FramesBefore → $p1FramesAfter）',
      );
    } else {
      log('✅ Phase 1 PASS：中途变尺寸后跟随且流存活');
    }

    // ---- Phase 2：尺寸模式三态循环 ----
    log('⑤ Phase 2：尺寸模式循环 fit→stretch→actual→fit…');
    for (final expect in ['stretch', 'actual', 'fit']) {
      await remote.click('#size-toggle');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final disp = await remote.evaluate('''
        (() => {
          const stage = document.getElementById('stage-video');
          const vv = window.__remote.videoView;
          const el = vv.canvas && !vv.canvas.classList.contains('hidden')
              ? vv.canvas : vv.mseVideo;
          return JSON.stringify({
            label: document.getElementById('size-toggle').textContent,
            stage: [stage.clientWidth, stage.clientHeight],
            style: el ? [el.style.width, el.style.height] : null,
            src: [vv.viewportWidth, vv.viewportHeight],
          });
        })()
      ''');
      final d = jsonDecode(disp as String) as Map<String, dynamic>;
      final stage = (d['stage'] as List).cast<int>();
      final style = d['style'] as List?;
      final src = (d['src'] as List).cast<int>();
      var ok = false;
      if (expect == 'stretch' && style != null) {
        ok = style[0] == '${stage[0]}px' && style[1] == '${stage[1]}px';
      } else if (expect == 'actual' && style != null) {
        ok = style[0] == '${src[0]}px' && style[1] == '${src[1]}px';
      } else if (expect == 'fit' && style != null) {
        // fit：等比内嵌，宽或高撑满、另一维 ≤ 舞台
        final w = int.tryParse('${style[0]}'.replaceAll('px', '')) ?? 0;
        final h = int.tryParse('${style[1]}'.replaceAll('px', '')) ?? 0;
        ok = w <= stage[0] && h <= stage[1] && (w == stage[0] || h == stage[1]);
      }
      log(
        '   $expect：label=${d['label']} stage=${stage[0]}x${stage[1]} '
        'style=$style src=${src[0]}x${src[1]} → ${ok ? "✓" : "✗"}',
      );
      if (!ok) failures++;
    }

    // fit 落定后再验一次视口跟随（用户主诉：切来切去都固定尺寸）
    final p2Ok = await _waitFixtureViewport(
      page,
      remote,
      const Duration(seconds: 10),
    );
    await _dumpState(page, remote, session, 'Phase 2 落定');
    if (!p2Ok) {
      failures++;
      log('❌ Phase 2 FAIL：循环一圈回到 fit 后视口未跟随');
    } else {
      log('✅ Phase 2 PASS');
    }

    // ---- Phase R：宿主会话重启、远程页面不刷新（用户主诉场景）----
    // 宿主 App 重启/会话重建后，远程端 WS 自动重连：applyMode('video')
    // 因 currentMode 已是 'video' 早退，不会重发 setViewport；若宿主
    // stop() 清除了覆盖，目标页就停留在旧视口（「固定尺寸」）。
    log('⑥ Phase R：重启 VideoSession（远程页面保持不动）…');
    await session.stop();
    session = VideoSession(
      page: page,
      relay: relay,
      locator: const FfmpegLocator(),
    );
    await session.start();
    log(
      '   会话重启后 fixture 视口=${await page.evaluate('innerWidth')}x${await page.evaluate('innerHeight')}',
    );
    // 等远程端重连 + 视口跟随落定
    await _waitTrue(
      remote,
      'window.__remote.videoView.framesDecoded > 3',
      '重连后重新出帧',
    );
    final pROk = await _waitFixtureViewport(
      page,
      remote,
      const Duration(seconds: 15),
    );
    await _dumpState(page, remote, session, 'Phase R 落定');
    if (!pROk) {
      failures++;
      log('❌ Phase R FAIL：会话重启后视口未重新跟随（远程页面未刷新）');
    } else {
      log('✅ Phase R PASS：会话重启后视口重新跟随');
    }

    log(failures == 0 ? '✅ 复现脚本全绿（bug 未复现）' : '❌ 复现到 $failures 处失败');
    exitCode = failures == 0 ? 0 : 1;
  } finally {
    await browser?.close();
    await session?.stop();
    await relay.stop();
    await connection?.client.close();
    await launcher.stop(profile);
  }
}

/// 轮询直到 fixture 视口 == 远程舞台尺寸（容差 2px）。
Future<bool> _waitFixtureViewport(
  CdpPage page,
  pp.Page remote,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final stage = await remote.evaluate('''
      (() => {
        const s = document.getElementById('stage-video');
        return JSON.stringify([s.clientWidth, s.clientHeight]);
      })()
    ''');
    final dims = (jsonDecode(stage as String) as List).cast<int>();
    final vw = await page.evaluate('innerWidth');
    final vh = await page.evaluate('innerHeight');
    if ((vw as num).toInt() >= dims[0] - 2 &&
        (vw).toInt() <= dims[0] + 2 &&
        (vh as num).toInt() >= dims[1] - 2 &&
        (vh).toInt() <= dims[1] + 2) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  return false;
}

Future<void> _waitTrue(pp.Page remote, String expr, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    if (await remote.evaluate(expr) == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  throw StateError('等待超时：$what');
}

Future<void> _dumpState(
  CdpPage page,
  pp.Page remote,
  VideoSession? session,
  String tag,
) async {
  final vw = await page.evaluate('innerWidth');
  final vh = await page.evaluate('innerHeight');
  final diag = await remote.evaluate('''
    (() => {
      const vv = window.__remote.videoView;
      const stage = document.getElementById('stage-video');
      return JSON.stringify({
        metaViewport: [vv.viewportWidth, vv.viewportHeight],
        stage: [stage.clientWidth, stage.clientHeight],
        sizeLabel: document.getElementById('size-toggle').textContent,
        framesDecoded: vv.framesDecoded,
        lastError: vv.lastError,
        svLog: (window.__svLog || []).slice(-6),
        wsState: window.__remote.client._ws ? window.__remote.client._ws.readyState : -1,
      });
    })()
  ''');
  final st = session?.status;
  log(
    '[$tag] fixture视口=${vw}x$vh host.lastError=${st?.lastError} '
    'aus=${st?.ausSent} remote=$diag',
  );
}
