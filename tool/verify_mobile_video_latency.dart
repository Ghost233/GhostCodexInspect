// 隔离的手机视频回归：DPR=3、HTTP MSE、静止流量与真实触摸到新画面的延迟。
// 验收：中位数 <300ms、最长 <500ms、编码队列 <=3、静止视频 <150kbps。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

Future<void> main() async {
  const port = 9243;
  try {
    final s = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 200),
    );
    s.destroy();
    throw StateError('Fixture port busy');
  } on SocketException {
    // 端口空闲，可以启动本次隔离 fixture。
  }
  final profile = await Directory.systemTemp.createTemp('gci-latency-');
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
  CdpConnection? conn;
  pp.Browser? browser;
  VideoSession? video;
  final relay = RelayServer(staticDir: 'assets/web');
  Future<void> wait(pp.Page p, String expr, {int ms = 15000}) async {
    final until = DateTime.now().add(Duration(milliseconds: ms));
    while (DateTime.now().isBefore(until)) {
      if (await p.evaluate(expr) == true) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('Timed out: $expr');
  }

  try {
    for (var i = 0; i < 50; i++) {
      try {
        conn = await connectCdp(debugPort: port);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (conn == null) throw StateError('Fixture failed to start');
    final page = await conn.client.attachTo(
      findShellTarget(await conn.client.listTargets(), ['file']),
    );
    await page.evaluate('''(() => {
      document.body.style.cssText='margin:0;background:#181818;color:#ddd;font:14px/1.6 monospace';
      document.body.innerHTML='<div id="mark" style="position:fixed;z-index:5;left:0;top:0;width:40px;height:40px;background:#ff0000"></div>'+Array.from({length:90},(_,i)=>'<p>'+i+'　远程控制输入、流量与清晰度检查　const value = '+i+'; return response.data; '.repeat(5)+'</p>').join('');
      window.__flip=0; document.body.addEventListener('click',()=>{window.__flip++;document.getElementById('mark').style.background=window.__flip%2?'#0000ff':'#ff0000';});
    })()''');
    await relay.start();
    video = VideoSession(page: page, relay: relay);
    await video.start();
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
    final remote = await browser.newPage();
    await remote.evaluateOnNewDocument(
      "localStorage.setItem('gci.videoPlaybackPath','mse');localStorage.setItem('gci.viewZoom','50');",
    );
    await remote.goto(relay.accessUrl.toString(), wait: pp.Until.load);
    await wait(remote, 'window.__remote?.videoView.video.currentTime>0');
    await remote.evaluate(
      "document.addEventListener('pointerdown',()=>{window.__tapAt=performance.now();},true)",
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    var bytes = video.status.bytesSent;
    await Future<void>.delayed(const Duration(seconds: 3));
    final idleKbps = (video.status.bytesSent - bytes) * 8 / 3000;
    stdout.writeln(
      'IDLE ${idleKbps.round()} kbps encoder=${video.status.encoder} encoded=${video.status.framesEncoded} aus=${video.status.ausSent} idr=${video.status.idrAusSent}',
    );
    final samples = <int>[];
    for (var i = 0; i < 8; i++) {
      await remote.touchscreen.tap(pp.Point(195, 250));
      try {
        await wait(
          remote,
          '''(() => {const v=window.__remote.videoView.video,c=document.createElement('canvas');c.width=c.height=1;const x=c.getContext('2d');x.drawImage(v,10,10,1,1,0,0,1,1);const p=x.getImageData(0,0,1,1).data;return ${i % 2 == 0 ? 'p[2]>180&&p[0]<80' : 'p[0]>180&&p[2]<80'};})()''',
          ms: 5000,
        );
      } catch (_) {
        stdout.writeln(
          'TIMEOUT sourceClicks=${await page.evaluate("window.__flip")} hostQueue=${video.status.encodeQueueDepth} hostError=${video.status.lastError} video=${await remote.evaluate("JSON.stringify({time:window.__remote.videoView.video.currentTime,buffer:window.__remote.videoView.video.buffered.length,error:window.__remote.videoView.lastError})")}',
        );
        rethrow;
      }
      samples.add(
        (await remote.evaluate('performance.now()-window.__tapAt') as num)
            .round(),
      );
      stdout.writeln(
        'CLICK ${samples.last} ms; host_queue=${video.status.encodeQueueDepth}',
      );
    }
    final metrics = await remote.evaluate(
      '''JSON.stringify((()=>{const v=window.__remote.videoView;return {engine:v._engine,buffer:v.video.buffered.length?v.video.buffered.end(v.video.buffered.length-1)-v.video.currentTime:0,frames:v.framesDecoded,error:v.lastError,resolution:[v.video.videoWidth,v.video.videoHeight]};})())''',
    );
    samples.sort();
    final p95 = samples.last;
    stdout.writeln(
      'RESULT ${jsonEncode({'idleKbps': idleKbps.round(), 'clickP95ms': p95, 'samplesMs': samples, 'hostQueue': video.status.encodeQueueDepth, 'fed': video.status.framesEncoded, 'aus': video.status.ausSent, 'idr': video.status.idrAusSent, 'remote': jsonDecode(metrics as String)})}',
    );
    if (samples[samples.length ~/ 2] > 300 ||
        p95 > 500 ||
        video.status.encodeQueueDepth > 3 ||
        idleKbps > 150) {
      exitCode = 1;
    }
  } finally {
    await video?.stop();
    await browser?.close();
    await relay.stop();
    await conn?.client.close();
    fixture.kill();
    await fixture.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        fixture.kill(ProcessSignal.sigkill);
        stderr.writeln('Fixture cleanup timed out');
        exitCode = 1;
        return -1;
      },
    );
    await profile.delete(recursive: true);
  }
}
