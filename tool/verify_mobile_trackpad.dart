// 隔离 Electron + 手机浏览器：DOM／视频两种模式验证触控板可信输入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/dom/editable_regions.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/protocol/input.dart' show TouchPoint;
import 'package:puppeteer/puppeteer.dart' as pp;

Future<void> main() async {
  const port = 9245;
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 200),
    );
    socket.destroy();
    throw StateError('测试端口已占用');
  } on SocketException {
    /* 端口空闲 */
  }
  final profile = await Directory.systemTemp.createTemp('gci-trackpad-');
  final fixture = await Process.start(
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
  CdpConnection? connection;
  pp.Browser? browser;
  DomSession? dom;
  VideoSession? video;
  EditableRegions? regions;
  final relay = RelayServer(staticDir: 'assets/web');
  Future<void> until(Future<bool> Function() condition, String message) async {
    final end = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(end)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError(message);
  }

  try {
    for (var i = 0; i < 50; i++) {
      try {
        connection = await connectCdp(debugPort: port);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (connection == null) throw StateError('Fixture 未启动');
    final page = await connection.client.attachTo(
      findShellTarget(await connection.client.listTargets(), ['file']),
    );
    await page.evaluate('''(() => {
      Object.assign(document.body.style,{minHeight:'3000px'});
      Object.assign(document.getElementById('counter-btn').style,{position:'fixed',left:'40%',top:'40%',width:'70px',height:'40px'});
      Object.assign(document.getElementById('echo-input').style,{position:'fixed',left:'30%',top:'60%',width:'160px',margin:'0'});
      window.__right=0;window.__drag=0;window.__held=false;window.__double=0;
      window.addEventListener('dblclick',()=>window.__double++);
      window.addEventListener('contextmenu',e=>{e.preventDefault();window.__right++;});
      window.addEventListener('mousedown',e=>{window.__held=true;window.__lastDown={x:e.clientX,y:e.clientY,target:e.target.id};});
      window.addEventListener('mouseup',()=>window.__held=false);
      window.addEventListener('mousemove',e=>{if(e.buttons===1)window.__drag++;});
    })()''');
    await relay.start(allowLanAccess: true);
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final ip = interfaces
        .expand((i) => i.addresses)
        .firstWhere((a) => !a.isLoopback)
        .address;
    final url = 'http://$ip:${relay.port}/#t=${relay.token}';
    browser = await pp.puppeteer.launch(
      executablePath:
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
      headless: true,
      defaultViewport: pp.DeviceViewport(
        width: 390,
        height: 844,
        deviceScaleFactor: 3,
        hasTouch: true,
      ),
    );
    for (final mode in ['dom', 'video']) {
      if (mode == 'dom') {
        dom = DomSession(page: page, relay: relay);
        await dom.start();
      } else {
        video = VideoSession(page: page, relay: relay);
        await video.start();
      }
      regions = EditableRegions(page, relay);
      await regions.start();
      final remote = await browser.newPage();
      remote.onError.listen((error) => stderr.writeln('PAGE ERROR: $error'));
      await remote.goto(url, wait: pp.Until.load);
      await until(
        () => remote.evaluate<bool>(
          "window.__remote?.client.authed===true && document.getElementById('mode-label').textContent==='${mode == 'dom' ? 'DOM 重绘模式' : '视频流模式'}'",
        ),
        '会话未就绪',
      );
      if (mode == 'video') {
        await until(
          () => remote.evaluate<bool>(
            'window.__remote.videoView.video.videoWidth===1170',
          ),
          '视频分辨率不匹配',
        );
      } else {
        await until(
          () => remote.evaluate<bool>(
            "!!document.querySelector('#replayer-host iframe')?.contentDocument?.getElementById('counter-btn')",
          ),
          'DOM 尚未重建',
        );
        await until(
          () => remote.evaluate<bool>(
            "window.__remote.session.sourceWidth===390 && window.__remote.session.sourceHeight===document.getElementById('stage-dom').clientHeight",
          ),
          'DOM 视口未收敛',
        );
      }
      await remote.click('#more-settings summary');
      await remote.select('#input-mode', ['trackpad']);
      await remote.click('#more-settings summary');
      final pointer = mode == 'dom'
          ? 'window.__remote.inputLayer.pointer'
          : 'window.__remote.videoView.pointer';
      Future<void> swipe(num dx, num dy) async {
        await remote.devTools.input.dispatchTouchEvent('touchStart', [
          TouchPoint(x: 100, y: 400, id: 1),
        ]);
        await remote.devTools.input.dispatchTouchEvent('touchMove', [
          TouchPoint(x: 100 + dx, y: 400 + dy, id: 1),
        ]);
        await remote.devTools.input.dispatchTouchEvent('touchEnd', []);
      }

      Future<void> aim(String selector) async {
        final bounds = jsonDecode(
          await page.evaluate(
            "JSON.stringify((()=>{const r=document.querySelector('$selector').getBoundingClientRect();return {x:r.left+r.width/2,y:r.top+r.height/2};})())",
          ) as String,
        ) as Map;
        final delta = jsonDecode(
          await remote.evaluate(
            "JSON.stringify((()=>{const p=$pointer.point();const q=$pointer.toSource({clientX:p.x+1,clientY:p.y+1});return {x:(${bounds['x']}-p.source.x)/(q.x-p.source.x),y:(${bounds['y']}-p.source.y)/(q.y-p.source.y)};})())",
          ) as String,
        ) as Map;
        await swipe(delta['x'] as num, delta['y'] as num);
      }

      final clicks = await page.evaluate('count') as num;
      await aim('#counter-btn');
      await remote.touchscreen.tap(pp.Point(100, 400));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await page.evaluate('count') != clicks + 1) {
        stderr.writeln(
          'CLICK DIAGNOSTIC $mode source=${await page.evaluate("JSON.stringify({width:innerWidth,height:innerHeight,down:window.__lastDown,count,rect:document.getElementById('counter-btn').getBoundingClientRect()})")} cursor=${await remote.evaluate("JSON.stringify($pointer.point())")}',
        );
      }
      await until(
        () async => await page.evaluate('count') == clicks + 1,
        '模拟鼠标点击未命中目标按钮',
      );
      if (await remote.evaluate(
            "document.activeElement.classList.contains('ime-proxy')",
          ) ==
          true) {
        throw StateError('普通点击唤起了键盘');
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final doubles = await page.evaluate('window.__double') as num;
      await remote.touchscreen.tap(pp.Point(100, 400));
      await remote.touchscreen.tap(pp.Point(100, 400));
      await until(
        () async => (await page.evaluate('window.__double') as num) > doubles,
        '双击未送达目标',
      );
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final gestureDrag = await page.evaluate('window.__drag') as num;
      await remote.touchscreen.tap(pp.Point(100, 400));
      await remote.devTools.input.dispatchTouchEvent('touchStart', [
        TouchPoint(x: 100, y: 400, id: 1),
      ]);
      await remote.devTools.input.dispatchTouchEvent('touchMove', [
        TouchPoint(x: 130, y: 420, id: 1),
      ]);
      await remote.devTools.input.dispatchTouchEvent('touchEnd', []);
      await until(
        () async =>
            (await page.evaluate('window.__drag') as num) > gestureDrag &&
            await page.evaluate('window.__held') == false,
        '双击按住拖拽未保持左键',
      );
      final rightBefore = await page.evaluate('window.__right') as num;
      await remote.devTools.input.dispatchTouchEvent('touchStart', [
        TouchPoint(x: 90, y: 400, id: 1),
        TouchPoint(x: 180, y: 400, id: 2),
      ]);
      await remote.devTools.input.dispatchTouchEvent('touchEnd', []);
      await until(
        () async =>
            (await page.evaluate('window.__right') as num) > rightBefore,
        '双指右键未送达',
      );
      final scroll = await page.evaluate('scrollY') as num;
      await remote.devTools.input.dispatchTouchEvent('touchStart', [
        TouchPoint(x: 90, y: 500, id: 1),
        TouchPoint(x: 180, y: 500, id: 2),
      ]);
      await remote.devTools.input.dispatchTouchEvent('touchMove', [
        TouchPoint(x: 90, y: 400, id: 1),
        TouchPoint(x: 180, y: 400, id: 2),
      ]);
      await remote.devTools.input.dispatchTouchEvent('touchEnd', []);
      await until(
        () async => (await page.evaluate('scrollY') as num) > scroll,
        '双指滚轮未滚动目标页面',
      );
      await aim('#echo-input');
      await remote.touchscreen.tap(pp.Point(100, 400));
      await until(
        () => remote.evaluate<bool>(
          "document.activeElement.classList.contains('ime-proxy')",
        ),
        '点击输入框未唤起键盘代理',
      );
      await remote.keyboard.type(mode);
      await until(
        () async => (await page.evaluate(
          "document.getElementById('echo-input').value",
        ) as String).contains(mode),
        '键盘输入未进入目标输入框',
      );
      final dragBefore = await page.evaluate('window.__drag') as num;
      await remote.click('#mouse-drag');
      await swipe(30, 20);
      await remote.click('#mouse-drag');
      await until(
        () async =>
            (await page.evaluate('window.__drag') as num) > dragBefore &&
            await page.evaluate('window.__held') == false,
        '拖拽状态未保持或未释放',
      );
      await File('/private/tmp/gci-trackpad-$mode.png')
          .writeAsBytes(await remote.screenshot());
      await remote.click('#mouse-drag');
      await until(
        () async => await page.evaluate('window.__held') == true,
        '断线前未进入拖拽',
      );
      await remote.evaluate('window.__remote.client.disconnect()');
      await until(
        () async => await page.evaluate('window.__held') == false,
        '断线后鼠标仍被按住',
      );
      await remote.close();
      stdout.writeln(
        'PASS $mode: relative cursor, click, double click, gesture drag, right click, scroll, keyboard, drag lock and disconnect release.',
      );
      regions.stop();
      regions = null;
      await dom?.stop();
      dom = null;
      await video?.stop();
      video = null;
    }
  } finally {
    regions?.stop();
    await video?.stop();
    await dom?.stop();
    await browser?.close();
    await relay.stop();
    await connection?.client.close();
    fixture.kill();
    await fixture.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fixture.kill(ProcessSignal.sigkill);
        exitCode = 1;
        return -1;
      },
    );
    await profile.delete(recursive: true);
  }
}
