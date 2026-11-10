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
      time:v?.video.currentTime,buffer:v?.video.buffered.length,
      layout:[v?.viewportWidth,v?.viewportHeight,v?.deviceScaleFactor],
      pixels:[v?.video.videoWidth,v?.video.videoHeight],
      stage:[document.getElementById("stage-video")?.clientWidth,document.getElementById("stage-video")?.clientHeight]};
  })())'''),
  );
  throw StateError('等待失败：$expression');
}

Future<void> main(List<String> args) async {
  final real = args.contains('--codex');
  final dpr = args.contains('--retina') ? 3.0 : 1.0;
  final videoOnly = args.contains('--video-only');
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
        // 实机只连接选中的 page，避开其他内部页面更换上下文时的干扰。
        connection = await connectCdp(debugPort: port, preferRaw: real);
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
      final originalTarget = target;
      target = await createCodexRemoteWindow(connection.client, ['app']);
      ownedTargetId = target.id;
      originalPage = await connection.client.attachTo(originalTarget);
    }
    final page = await connection.client.attachTo(target);
    var ready = false;
    for (var i = 0; i < 50; i++) {
      try {
        ready =
            await page.evaluate(
              "document.readyState === 'complete' && !!document.body",
            ) ==
            true;
        if (ready) break;
      } catch (_) {
        /* 新建窗口导航时执行上下文会更替。 */
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!ready) throw StateError('目标窗口未完成加载');
    await relay.start(allowLanAccess: true);
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final ip = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback)
        .address;
    final url = 'http://$ip:${relay.port}/#t=${relay.token}';
    if (!videoOnly) {
      dom = DomSession(page: page, relay: relay);
      await dom.start();
      regions = EditableRegions(page, relay);
      await regions.start();
    }
    browser = await pp.puppeteer.launch(
      executablePath:
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: true,
      defaultViewport: pp.DeviceViewport(
        width: 390,
        height: 844,
        hasTouch: true,
        deviceScaleFactor: dpr,
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
    await waitFor(remote, 'window.__remote?.client.authed === true');
    if (!videoOnly) {
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
          pp.DeviceViewport(
            width: 390,
            height: 544,
            hasTouch: true,
            deviceScaleFactor: dpr,
          ),
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
          pp.DeviceViewport(
            width: 390,
            height: 844,
            hasTouch: true,
            deviceScaleFactor: dpr,
          ),
        );
        await remote.evaluate('document.activeElement.blur()');
        stdout.writeln(
          'PASS keyboard: touch gating and pan without stage/source resize.',
        );
      }
      regions!.stop();
      await dom!.stop();
      dom = null;
    }
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
    if (dpr > 1) {
      for (final zoom in [100, 50]) {
        if (zoom == 50) {
          for (var i = 0; i < 10; i++) {
            await remote.click('#zoom-out');
          }
        }
        await waitFor(remote, '''(() => {
          const v=window.__remote.videoView, stage=document.getElementById('stage-video');
          return Math.abs(v.video.videoWidth-stage.clientWidth*devicePixelRatio)<=2 &&
            Math.abs(v.video.videoHeight-stage.clientHeight*devicePixelRatio)<=2 &&
            Math.abs(v.viewportWidth-stage.clientWidth*100/$zoom)<=1;
        })()''');
        // 用帧内标记确认缩放后的画面已经解码呈现，避免把旧冻结帧误判为通过。
        await page.evaluate('''(() => {
          let marker=document.getElementById('__gciRetinaMarker');
          if (!marker) { marker=document.createElement('div');marker.id='__gciRetinaMarker';document.body.appendChild(marker); }
          Object.assign(marker.style,{position:'fixed',left:'0',top:'0',width:'20px',height:'20px',zIndex:'2147483647',background:'${zoom == 100 ? '#ff0000' : '#0000ff'}'});
        })()''');
        await waitFor(remote, '''(() => {
          const v=window.__remote.videoView.video, c=document.createElement('canvas');
          c.width=1;c.height=1;const ctx=c.getContext('2d');ctx.drawImage(v,10,10,1,1,0,0,1,1);
          const p=ctx.getImageData(0,0,1,1).data;
          return ${zoom == 100 ? 'p[0]>180 && p[2]<80' : 'p[2]>180 && p[0]<80'};
        })()''');
        stdout.writeln(
          'PASS retina $zoom%: ${await remote.evaluate("JSON.stringify({dpr:devicePixelRatio,layout:[window.__remote.videoView.viewportWidth,window.__remote.videoView.viewportHeight],frame:[window.__remote.videoView.video.videoWidth,window.__remote.videoView.video.videoHeight],scale:window.__remote.videoView.deviceScaleFactor})")}',
        );
        await File('/private/tmp/gci-retina-$zoom.png')
            .writeAsBytes(await remote.screenshot());
      }
    }
    await File('/private/tmp/gci-mobile-${real ? 'codex-' : ''}video.png')
        .writeAsBytes(await remote.screenshot());
    final late = await browser.newPage();
    await late.goto(url, wait: pp.Until.load);
    await waitFor(late, 'window.__remote.videoView.video.currentTime > 0');
    if (dpr > 1) {
      await waitFor(late, '''(() => {
        const v=window.__remote.videoView.video,c=document.createElement('canvas');
        c.width=c.height=1;const x=c.getContext('2d');x.drawImage(v,10,10,1,1,0,0,1,1);
        const p=x.getImageData(0,0,1,1).data;return p[2]>180 && p[0]<80;
      })()''');
    }
    stdout.writeln(
      'PASS late join: second HTTP MSE client plays the existing stream.',
    );
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    rethrow;
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
