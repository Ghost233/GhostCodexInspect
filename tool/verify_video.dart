// 视频流模式端到端验收（工单 #22，fixture 版）。
//
// 用法：`dart run tool/verify_video.dart`（需本机有 ffmpeg）。
//
// 验收点：
// 1. fixture（9240）→ CDP attach → VideoSession 启动，videoMeta 广播；
// 2. Phase A（Dart WS 客户端，v1 文本）：收到 videoMeta + videoFrame AU，
//    远程点击回灌 fixture 按钮（标题计数变化）；
// 3. Phase B（headless Chrome）：切「视频流模式」，WebCodecs 解码出帧
//    （canvas has-frame + framesDecoded>0）；切 MSE 播放路径后 video
//    元素有 buffered 数据；点击回灌。
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
import 'package:web_socket_channel/web_socket_channel.dart';

const int debugPort = 9240; // 与真机 9238 分离（2026-10-17 事故教训）
const String chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void log(String msg) => stderr.writeln('[verify-video] $msg');

Future<void> main() async {
  final fixtureApp = Directory('tool/fixture').existsSync()
      ? 'tool/fixture'
      : '../tool/fixture';

  // 端口预检：9240 被占用（多半是残留 fixture）直接拒绝启动。
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

  try {
    log('② CDP attach 主窗口…');
    connection = await connectCdp(debugPort: debugPort, preferRaw: false);
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['file']);
    final page = await connection.client.attachTo(shell);
    log('   shell=${shell.url}（${connection.implementationName}）');

    log('③ 启动中转 + VideoSession…');
    await relay.start();
    session = VideoSession(
      page: page,
      relay: relay,
      locator: const FfmpegLocator(),
    );
    await session.start();
    log('   encoder=${session.status.encoder} accessUrl=${relay.accessUrl}');

    log('④ Phase A：Dart WS 客户端（v1 文本）收 meta + AU…');
    final ws = WebSocketChannel.connect(
      Uri.parse(
        '${relay.accessUrl.toString().replaceFirst('http', 'ws').split('#').first}ws',
      ),
    );
    await ws.ready;
    ws.sink.add(
      jsonEncode({
        'v': 1,
        'ch': 'ctrl',
        't': 'auth',
        'seq': 0,
        'ts': 0,
        'data': {'token': relay.token},
      }),
    );
    var metaSeen = false;
    var auCount = 0;
    final wsSub = ws.stream.listen((e) {
      if (e is! String) return;
      final env = RelayEnvelope.tryDecode(e);
      if (env == null || env.channel != RelayChannel.video) return;
      if (env.type == RelayMessageType.videoMeta) metaSeen = true;
      if (env.type == RelayMessageType.videoFrame) auCount++;
    });

    // 画面要有变化才会出帧：启动 fixture 动画
    await page.evaluate(
      "(function __gciBlink(){ if (!document.body) { setTimeout(__gciBlink, 50); return; } setInterval(() => { document.body.style.filter = document.body.style.filter ? '' : 'invert(1)'; }, 100); })()",
    );
    // VT 内部缓冲大（调试实测约 46 帧才放行首批 AU），放宽等待窗口
    final auDeadline = DateTime.now().add(const Duration(seconds: 40));
    while (auCount < 10 && DateTime.now().isBefore(auDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    if (!metaSeen) throw StateError('40s 内未收到 videoMeta');
    log(
      '   videoMeta ✓ AU=$auCount（宿主 ausSent=${session.status.ausSent} framesEncoded=${session.status.framesEncoded} idrSent=${session.status.idrAusSent}）',
    );
    if (auCount < 10) throw StateError('AU 数量过少：$auCount');
    log(
      '   AU 信封 ✓（视频字节 ${(session.status.bytesSent / 1024).toStringAsFixed(1)} KB）',
    );

    // 远程点击回灌：读 fixture 计数按钮真实位置后点中心
    final btnRectJson = await page.evaluate(
      "JSON.stringify(document.getElementById('counter-btn').getBoundingClientRect())",
    );
    final btnRect = jsonDecode(btnRectJson as String) as Map<String, dynamic>;
    final cx = ((btnRect['left'] as num) + (btnRect['width'] as num) / 2)
        .round();
    final cy = ((btnRect['top'] as num) + (btnRect['height'] as num) / 2)
        .round();
    final before = await page.evaluate('document.title');
    var seq = 1;
    for (final action in ['down', 'up']) {
      ws.sink.add(
        jsonEncode({
          'v': 1,
          'ch': 'input',
          't': 'input',
          'seq': seq++,
          'ts': 0,
          'data': {
            'kind': 'mouse',
            'action': action,
            'x': cx,
            'y': cy,
            'button': 'left',
            'clickCount': 1,
          },
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = await page.evaluate('document.title');
    if (after == before) throw StateError('点击未回灌（title 未变化）');
    log('   输入回灌 ✓（title: $before → $after）');
    await wsSub.cancel();
    await ws.sink.close();

    log('⑤ Phase B：headless Chrome 远程端播放…');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--window-size=1280,900'],
    );
    final remote = await browser.newPage();
    await remote.goto('${relay.accessUrl}', wait: pp.Until.load);
    // 模式不再手选：首个 videoMeta 到达即自动切到视频窗格（2026-10-19）

    // WebCodecs 路径出帧（默认 auto）
    await _poll(
      remote,
      'window.__remote.videoView.framesDecoded > 3',
      'WebCodecs 解码出帧',
      diagPage: remote,
    );
    final canvasVisible = await remote.evaluate(
      "!document.querySelector('#video-host .video-canvas').classList.contains('hidden')",
    );
    if (canvasVisible != true) throw StateError('canvas 未显示');
    log('   WebCodecs 解码出帧 ✓');

    // 输入回灌（点 canvas 内按钮对应位置：按显示比例换算回源坐标）
    final rect = await remote.evaluate(
      "JSON.stringify(document.querySelector('#video-host .video-canvas').getBoundingClientRect())",
    );
    final r = jsonDecode(rect as String) as Map<String, dynamic>;
    final vw = await remote.evaluate('window.__remote.videoView.viewportWidth');
    final vh = await remote.evaluate(
      'window.__remote.videoView.viewportHeight',
    );
    final titleBefore = await page.evaluate('document.title');
    await remote.mouse.click(
      pp.Point(
        (r['left'] as num) + (r['width'] as num) * (cx / (vw as num)),
        (r['top'] as num) + (r['height'] as num) * (cy / (vh as num)),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final titleAfter = await page.evaluate('document.title');
    if (titleAfter == titleBefore) throw StateError('Phase B 点击未回灌');
    log('   Phase B 输入回灌 ✓');

    // 切 MSE 播放路径
    await remote.select('#playback-path', ['mse']);
    await remote.evaluate(
      "document.getElementById('playback-path').dispatchEvent(new Event('change'))",
    );
    await _poll(
      remote,
      '''
      (() => {
        const v = document.querySelector('#video-host .video-mse');
        return v && !v.classList.contains('hidden') && v.buffered.length > 0 && v.buffered.end(0) > 0.05;
      })()
    ''',
      'MSE buffered',
      diagPage: remote,
    );
    log('   MSE 播放路径 ✓');

    log('✅ 全部通过');
  } finally {
    await browser?.close();
    await session?.stop();
    await relay.stop();
    await connection?.client.close();
    await launcher.stop(profile);
  }
}

Future<void> _poll(
  pp.Page page,
  String expression,
  String what, {
  pp.Page? diagPage,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (DateTime.now().isBefore(deadline)) {
    final ok = await page.evaluate(expression);
    if (ok == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  if (diagPage != null) {
    final diag = await diagPage.evaluate('''
      (() => {
        const vv = window.__remote.videoView;
        const v = document.querySelector('#video-host .video-mse');
        return JSON.stringify({
          engine: vv._engine,
          lastError: vv.lastError,
          framesDecoded: vv.framesDecoded,
          hasMse: !!vv._mse, lastErr2: vv.lastError, bytesAppended: vv.mseBytesAppended || 0, queue: vv._mse ? vv._mse.queue.length : -1, aus: vv.ausReceived, keyAus: vv.keyAusReceived || 0, keyWaits: vv.mseKeyWaits,
          sb: vv._mse && vv._mse.sourceBuffer ? {updating: vv._mse.sourceBuffer.updating} : null,
          readyState: vv._mse ? vv._mse.mediaSource.readyState : null,
          videoHidden: v ? v.classList.contains('hidden') : null,
          videoError: v && v.error ? v.error.code : null,
          videoSrc: v ? (v.src || '').substring(0, 30) : null, conn: document.getElementById('conn-text').textContent, wsDbg: window.__wsDbg, fp: (vv.auFingerprints || []).slice(-8),
        });
      })()
    ''');
    log('诊断: $diag');
  }
  throw StateError('等待超时：$what');
}
