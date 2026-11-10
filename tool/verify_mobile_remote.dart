// 手机远程回归：真实 Electron fixture、局域网 HTTP、DOM 首屏和 MSE 首屏。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/dom/editable_regions.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

Future<void> waitFor(pp.Page page, String expression) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end)) {
    if (await page.evaluate(expression) == true) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  stderr.writeln(
    await page.evaluate('''JSON.stringify((() => {
    const r=window.__remote, v=r?.videoView;
    return {mode:document.getElementById('mode-label')?.textContent,
      engine:v?._engine,error:v?.lastError,aus:v?.ausReceived,keys:v?.keyAusReceived,
      missing:v?.mseMissingSps,bytes:v?.mseBytesAppended,
      mediaError:v?.video.error?.message,ready:v?.video.readyState,paused:v?.video.paused,
      time:v?.video.currentTime,buffer:v?.video.buffered.length};
  })())'''),
  );
  throw StateError('等待失败：$expression');
}

Future<void> main(List<String> args) async {
  final real = args.contains('--codex');
  final port = real ? 9238 : 9242;
  if (!real) {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 300),
      );
      socket.destroy();
      throw StateError('测试端口 $port 已占用，拒绝操作已有进程');
    } on SocketException {
      /* 空闲测试端口 */
    }
  }
  Directory? profile;
  Process? fixture;
  if (!real) {
    profile = await Directory.systemTemp.createTemp('gci-mobile-');
    fixture = await Process.start(
      '${Directory.current.path}/tool/fixture/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron',
      [
        '--remote-debugging-port=$port',
        '--user-data-dir=${profile.path}',
        '${Directory.current.path}/tool/fixture',
      ],
      environment: {'ELECTRON_RUN_AS_NODE': ''},
    );
    unawaited(fixture.stdout.drain<void>());
    unawaited(fixture.stderr.drain<void>());
  }
  CdpConnection? connection;
  pp.Browser? browser;
  final relay = RelayServer(staticDir: 'assets/web');
  DomSession? dom;
  VideoSession? video;
  EditableRegions? regions;
  String? ownedTargetId;
  CdpPage? originalPage;
  try {
    for (var i = 0; i < 50; i++) {
      try {
        connection = await connectCdp(debugPort: port);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (connection == null) throw StateError('fixture 未启动');
    var target = findShellTarget(await connection.client.listTargets(), [
      real ? 'app' : 'file',
    ]);
    if (real) {
      originalPage = await connection.client.attachTo(target);
      target = await createCodexRemoteWindow(connection.client, ['app']);
      ownedTargetId = target.id;
    }
    final page = await connection.client.attachTo(target);
    await relay.start(allowLanAccess: true);
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final ip = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback)
        .address;
    final url = 'http://$ip:${relay.port}/#t=${relay.token}';
    dom = DomSession(page: page, relay: relay);
    await dom.start();
    regions = EditableRegions(page, relay);
    await regions.start();
    browser = await pp.puppeteer.launch(
      executablePath:
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: true,
      defaultViewport: const pp.DeviceViewport(
        width: 390,
        height: 844,
        hasTouch: true,
      ),
    );
    final remote = await browser.newPage();
    remote.onError.listen((e) => stderr.writeln('PAGE ERROR: $e'));
    // 模拟手机时钟落后宿主一分钟，首屏仍必须及时出现。
    await remote.evaluateOnNewDocument('''(() => {
      const now=Date.now.bind(Date); Date.now=() => now()-60000;
    })()''');
    await remote.evaluateOnNewDocument('''(() => {
      window.__viewportRequests = [];
      const send = WebSocket.prototype.send;
      WebSocket.prototype.send = function(data) {
        if (typeof data === 'string') { try { const e = JSON.parse(data); if(e.t === 'setViewport') window.__viewportRequests.push(e.data); } catch (_) {} }
        return send.call(this, data);
      };
    })()''');
    await remote.goto(url, wait: pp.Until.load);
    await waitFor(
      remote,
      real
          ? "(document.querySelector('#replayer-host iframe')?.contentDocument?.body?.innerText.length || 0) > 50"
          : "document.querySelector('#replayer-host iframe')?.contentDocument?.getElementById('counter-btn')?.textContent === '点我'",
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await remote.evaluate(
      'window.__firstReplay = window.__remote.session.replayer',
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    if (await remote.evaluate(
          'window.__firstReplay === window.__remote.session.replayer',
        ) !=
        true) {
      stderr.writeln(
        await remote.evaluate(
          'JSON.stringify({requests:window.__viewportRequests,source:[window.__remote.session.sourceWidth,window.__remote.session.sourceHeight],stage:[document.getElementById("stage-dom").clientWidth,document.getElementById("stage-dom").clientHeight]})',
        ),
      );
      throw StateError('DOM 首屏仍重复重建');
    }
    await waitFor(
      remote,
      'window.__remote.inputLayer.keyboard.targets.length > 0',
    );
    stdout.writeln(
      'PASS DOM: LAN HTTP first screen visible and stable; editable input regions delivered.',
    );
    await File('/private/tmp/gci-mobile-${real ? 'codex-' : ''}dom.png')
        .writeAsBytes(await remote.screenshot());
    if (!real) {
      await page.evaluate(
        "Object.assign(document.getElementById('echo-input').style,{position:'fixed',bottom:'48px',marginTop:'0'})",
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await waitFor(
        remote,
        "document.querySelector('#replayer-host iframe').contentDocument.querySelector('#echo-input').getBoundingClientRect().top > 600",
      );
      Future<void> tapDom(String selector) async {
        final raw = await remote.evaluate('''JSON.stringify((() => {
          const frame=document.querySelector('#replayer-host iframe'), r=frame.getBoundingClientRect();
          const t=frame.contentDocument.querySelector('$selector').getBoundingClientRect(), s=window.__remote.session.scale;
          return {x:r.left+(t.left+t.width/2)*s,y:r.top+(t.top+t.height/2)*s};
        })())''');
        final p = jsonDecode(raw as String) as Map;
        await remote.touchscreen.tap(pp.Point(p['x'] as num, p['y'] as num));
      }

      await tapDom('#counter-btn');
      if (await remote.evaluate(
            "document.activeElement.classList.contains('ime-proxy')",
          ) ==
          true) {
        throw StateError('普通点击打开了键盘');
      }
      await tapDom('#echo-input');
      if (await remote.evaluate(
            "document.activeElement.classList.contains('ime-proxy')",
          ) !=
          true) {
        stderr.writeln(
          await remote.evaluate(
            "JSON.stringify({targets:window.__remote.inputLayer.keyboard.targets,input:document.querySelector('#replayer-host iframe').contentDocument.querySelector('#echo-input').getBoundingClientRect(),frame:document.querySelector('#replayer-host iframe').getBoundingClientRect(),active:document.activeElement.tagName})",
          ),
        );
        throw StateError('输入框点击没有聚焦');
      }
      final height = await remote.evaluate(
        "document.getElementById('stage-dom').clientHeight",
      );
      final sourceHeight = await page.evaluate('innerHeight');
      await remote.setViewport(
        const pp.DeviceViewport(width: 390, height: 544, hasTouch: true),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (await remote.evaluate(
                "document.getElementById('stage-dom').clientHeight",
              ) !=
              height ||
          await page.evaluate('innerHeight') != sourceHeight) {
        throw StateError('键盘占高时舞台或目标视口缩小');
      }
      if (await remote.evaluate(
            "document.querySelector('.stage').style.transform.startsWith('translateY(-')",
          ) !=
          true) {
        throw StateError('键盘占高时画面未向上平移');
      }
      await File('/private/tmp/gci-mobile-keyboard-pan.png')
          .writeAsBytes(await remote.screenshot());
      await remote.setViewport(
        const pp.DeviceViewport(width: 390, height: 844, hasTouch: true),
      );
      await remote.evaluate('document.activeElement.blur()');
      stdout.writeln(
        'PASS keyboard: touch gating and pan without stage/source resize.',
      );
    }
    regions.stop();
    await dom.stop();
    dom = null;
    video = VideoSession(page: page, relay: relay);
    await video.start();
    regions = EditableRegions(page, relay);
    await regions.start();
    final start = DateTime.now();
    try {
      await waitFor(remote, 'window.__remote.videoView.video.currentTime > 0');
    } catch (_) {
      stderr.writeln(
        'HOST VIDEO: encoding=${video.status.encoding} frames=${video.status.framesEncoded} aus=${video.status.ausSent} error=${video.status.lastError}',
      );
      rethrow;
    }
    final diag = await remote.evaluate(
      'JSON.stringify({secure:isSecureContext,engine:window.__remote.videoView._engine,time:window.__remote.videoView.video.currentTime,error:window.__remote.videoView.lastError})',
    );
    stdout.writeln(
      'PASS MSE: static LAN HTTP video playing after ${DateTime.now().difference(start).inMilliseconds} ms: $diag',
    );
    await File('/private/tmp/gci-mobile-${real ? 'codex-' : ''}video.png')
        .writeAsBytes(await remote.screenshot());
    final late = await browser.newPage();
    await late.goto(url, wait: pp.Until.load);
    await waitFor(late, 'window.__remote.videoView.video.currentTime > 0');
    stdout.writeln(
      'PASS late join: second HTTP MSE client plays the existing stream.',
    );
  } finally {
    regions?.stop();
    await browser?.close();
    await dom?.stop();
    await video?.stop();
    await relay.stop();
    if (ownedTargetId != null && originalPage != null) {
      await originalPage.send('Target.closeTarget', {
        'targetId': ownedTargetId,
      });
      await originalPage.send('Page.bringToFront');
    }
    await connection?.client.close();
    fixture?.kill();
    await fixture?.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fixture?.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await profile?.delete(recursive: true);
  }
}
