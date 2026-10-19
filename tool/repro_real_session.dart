// Bug 2 真机全栈复现（2026-10-19）：真实 Codex 页面 + 生产会话栈 +
// 用户现场状态（localStorage 存了「拉伸填满」）。
//
// 用法：`dart run tool/repro_real_session.dart`
// 前置：ChatGPT.app 带 --remote-debugging-port=9238 运行；宿主 App 未在跑
// （中转回调互斥）。
//
// 与 fixture 版（tool/repro_viewport_follow.dart，已全绿）的差异：
// 1. 目标是真实 Codex 页（9238）而非 fixture（9240）；
// 2. 远程端 localStorage 预置 gci.viewSizeMode=stretch（用户现场）；
// 3. 捕获远程端 console/pageerror（JS 异常静默会同时解释「不跟随」
//    与「切换无效」两个症状）。
//
// 注意：运行期间 Codex 窗口内容会短暂重排（视口覆盖），结束时
// session.stop() 清除覆盖恢复自然视口。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const String chromePath =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

void log(String msg) => stderr.writeln('[repro-real] $msg');

Future<void> main() async {
  log('① attach 真实 Codex（9238）…');
  final connection = await connectCdp(debugPort: 9238, preferRaw: false);
  final relay = RelayServer(staticDir: 'assets/web');
  VideoSession? session;
  pp.Browser? browser;
  var failures = 0;

  try {
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['app', 'file']);
    log('   shell=${shell.url} title=${shell.title}');
    final page = await connection.client.attachTo(shell);
    log(
      '   覆盖前视口=${await page.evaluate('JSON.stringify({iw:innerWidth,ih:innerHeight,dpr:devicePixelRatio})')}',
    );

    await relay.start();
    session = VideoSession(page: page, relay: relay);
    await session.start();
    log('   accessUrl=${relay.accessUrl}');

    log('② 启动 headless Chrome 远程端（预置 stretch，1280x800）…');
    browser = await pp.puppeteer.launch(
      executablePath: chromePath,
      headless: true,
      args: ['--window-size=1280,800'],
    );
    final remote = await browser.newPage();
    remote.onConsole.listen(
      (m) => log('   [remote.console.${m.type}] ${m.text}'),
    );
    remote.onResponse.listen((r) {
      if (r.status >= 400) log('   [remote.http ${r.status}] ${r.url}');
    });
    await remote.evaluateOnNewDocument('''
      (() => {
        try { localStorage.setItem('gci.viewSizeMode', 'stretch'); } catch (_) {}
        const origSend = WebSocket.prototype.send;
        window.__svLog = [];
        WebSocket.prototype.send = function (data) {
          try {
            if (typeof data === 'string' && data.includes('setViewport')) {
              const env = JSON.parse(data);
              window.__svLog.push({ w: env.data && env.data.width, h: env.data && env.data.height, t: Date.now(), readyState: this.readyState });
            }
          } catch (_) {}
          return origSend.call(this, data);
        };
        window.addEventListener('error', (e) => { (window.__jsErr = window.__jsErr || []).push(String(e.message)); });
        window.addEventListener('unhandledrejection', (e) => { (window.__jsErr = window.__jsErr || []).push('rejection: ' + String(e.reason)); });
      })()
    ''');
    await remote.goto('${relay.accessUrl}', wait: pp.Until.load);

    log('③ 等出帧 + 视口跟随落定（15s）…');
    try {
      await _waitTrue(
        remote,
        'window.__remote && window.__remote.videoView.framesDecoded > 3',
        'WebCodecs 出帧',
      );
    } catch (_) {
      // 出帧失败也要拿到全量诊断（远程端 JS 是否活着、宿主是否收到帧）
      await _dump(page, remote, session, '出帧超时');
      // 真实窗口可能被遮挡导致 screencast 无帧：注入 DOM 动画强制产生重绘
      log('   注入 DOM 动画强制产生画面变化后再等 20s…');
      await page.evaluate(
        "(function __gciBlink(){ if (!document.body) { setTimeout(__gciBlink, 50); return; } setInterval(() => { document.body.style.filter = document.body.style.filter ? '' : 'invert(1)'; }, 300); })()",
      );
      try {
        await _waitTrue(
          remote,
          'window.__remote && window.__remote.videoView.framesDecoded > 3',
          '注入动画后出帧',
        );
      } catch (_) {
        await _dump(page, remote, session, '注入动画后仍超时');
        rethrow;
      }
    }
    final followOk = await _waitFollow(
      page,
      remote,
      const Duration(seconds: 15),
    );
    await _dump(page, remote, session, '首载落定');
    if (!followOk) {
      failures++;
      log('❌ FAIL：首载视口未跟随（用户主诉复现）');
    } else {
      log('✅ 首载视口跟随正常');
    }

    log('④ 尺寸模式循环 stretch→actual→fit→stretch…');
    for (final expect in ['actual', 'fit', 'stretch']) {
      await remote.click('#size-toggle');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final disp = await remote.evaluate('''
        (() => {
          const stage = document.getElementById('stage-video');
          const vv = window.__remote.videoView;
          const el = vv.canvas && !vv.canvas.classList.contains('hidden') ? vv.canvas : vv.video;
          return JSON.stringify({
            label: document.getElementById('size-toggle').textContent,
            stage: [stage.clientWidth, stage.clientHeight],
            style: el ? [el.style.width, el.style.height] : null,
            src: [vv.viewportWidth, vv.viewportHeight],
            frames: vv.framesDecoded,
          });
        })()
      ''');
      log('   $expect → $disp');
    }
    await _dump(page, remote, session, '模式循环后');
    log(failures == 0 ? '✅ 真机全栈未复现' : '❌ 复现到 $failures 处失败');
    exitCode = failures == 0 ? 0 : 1;
  } finally {
    await browser?.close();
    await session?.stop(); // 清除视口覆盖，恢复自然视口
    await relay.stop();
    await connection.client.close();
  }
}

Future<bool> _waitFollow(CdpPage page, pp.Page remote, Duration timeout) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final stage = await remote.evaluate(
      "JSON.stringify([document.getElementById('stage-video').clientWidth, document.getElementById('stage-video').clientHeight])",
    );
    final dims = (jsonDecode(stage as String) as List).cast<int>();
    final vw = (await page.evaluate('innerWidth') as num).toInt();
    final vh = (await page.evaluate('innerHeight') as num).toInt();
    if ((vw - dims[0]).abs() <= 2 && (vh - dims[1]).abs() <= 2) return true;
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

Future<void> _dump(
  CdpPage page,
  pp.Page remote,
  VideoSession? session,
  String tag,
) async {
  final v = await page.evaluate(
    'JSON.stringify({iw:innerWidth,ih:innerHeight,dpr:devicePixelRatio})',
  );
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
        jsErr: window.__jsErr || [],
      });
    })()
  ''');
  final st = session?.status;
  log(
    '[$tag] codex视口=$v host.lastError=${st?.lastError} '
    'encoding=${st?.encoding} viewers=${st?.viewers} frames=${st?.framesEncoded} aus=${st?.ausSent} remote=$diag',
  );
}
