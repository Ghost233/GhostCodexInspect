// 连续检查视频四角、更新和边缘点击，防止像素尺寸正确但内容被裁切。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/video/video.dart';
import 'package:puppeteer/puppeteer.dart' as pp;

const _samplePixels = '''(image) => {
  const c=document.createElement('canvas');
  c.width=image.videoWidth || image.naturalWidth;
  c.height=image.videoHeight || image.naturalHeight;
  const x=c.getContext('2d');x.drawImage(image,0,0);
  const pts=[[.01,.01],[.99,.01],[.01,.99],[.99,.99],[.5,.5]];
  const colors=pts.map(([a,b])=>Array.from(x.getImageData(Math.floor(c.width*a),Math.floor(c.height*b),1,1).data).slice(0,3));
  const expected=[[255,0,0],[0,255,0],[0,0,255],[255,255,0]];
  return {corners:colors.slice(0,4).every((p,j)=>p.every((n,k)=>Math.abs(n-expected[j][k])<80)),colors,pixels:[c.width,c.height]};
}''';

Future<void> main(List<String> args) async {
  const port = 9246;
  try {
    final socket = await Socket.connect(
      '127.0.0.1',
      port,
      timeout: const Duration(milliseconds: 200),
    );
    socket.destroy();
    throw StateError('测试端口被占用');
  } on SocketException {
    // 只允许启动本次测试自己的目标。
  }
  final profile = await Directory.systemTemp.createTemp('gci-geometry-');
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
  VideoSession? video;
  StreamSubscription<ScreencastFrameData>? frameSub;
  String? lastCapture;
  Map<String, dynamic>? lastMeta;
  final relay = RelayServer(staticDir: 'assets/web');
  Future<void> wait(Future<bool> Function() check, String message) async {
    final end = DateTime.now().add(const Duration(seconds: 12));
    while (DateTime.now().isBefore(end)) {
      if (await check()) return;
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
      document.body.style.cssText='margin:0;background:#181818;overflow:hidden';
      document.body.innerHTML='';
      const specs=[['tl','left:0;top:0','#ff0000'],['tr','right:0;top:0','#00ff00'],['bl','left:0;bottom:0','#0000ff'],['br','right:0;bottom:0','#ffff00'],['center','left:45vw;top:45vh','#00ffff']];
      for(const [id,pos,color] of specs){const b=document.createElement('div');b.id=id;b.style.cssText='position:fixed;width:5vw;height:5vh;z-index:1000;background:'+color+';'+pos;b.onclick=()=>window.__corner=id;document.body.appendChild(b);}
      document.getElementById('center').style.width='10vw';
      document.getElementById('center').style.height='10vh';
    })()''');
    frameSub = page.screencastFrames.listen((f) {
      lastCapture = f.data;
      lastMeta = f.metadata;
    });
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
    var previousZoom = 50;
    for (final scenario in [
      (50, 390, 844, 3.0),
      (100, 390, 844, 3.0),
      (10, 390, 844, 3.0),
      (50, 844, 390, 3.0),
      (50, 840, 844, 2.75),
      (50, 390, 844, 2.75),
      (50, 390, 844, 3.0),
    ]) {
      if (args.contains('--fractional') && scenario.$4 != 2.75) continue;
      final (zoom, width, height, dpr) = scenario;
      await remote.setViewport(
        pp.DeviceViewport(
          width: width,
          height: height,
          deviceScaleFactor: dpr,
          hasTouch: true,
        ),
      );
      for (var i = 0; i < (zoom - previousZoom).abs() ~/ 5; i++) {
        await remote.click(zoom > previousZoom ? '#zoom-in' : '#zoom-out');
      }
      previousZoom = zoom;
      await remote.evaluate('window.__remote.client.setFrameRate(30)');
      // 编码尺寸必须与源视口一致；分数 DPR 换算到原生表面时可有一两 CSS 像素舍入。
      // 四角和逐帧中心颜色仍必须精确覆盖完整逻辑视口。
      try {
        await wait(
          () => remote.evaluate<bool>(
            '''(() => {const v=window.__remote?.videoView,s=document.getElementById('stage-video');return v?.video.currentTime>0.05 && v.video.videoWidth===Math.ceil(v.viewportWidth*v.deviceScaleFactor/2)*2 && v.video.videoHeight===Math.ceil(v.viewportHeight*v.deviceScaleFactor/2)*2 && Math.abs(v.viewportWidth-s.clientWidth*100/$zoom)<=2 && Math.abs(v.deviceScaleFactor-devicePixelRatio*$zoom/100)<.001;})()''',
          ),
          '视频视口未就绪: $scenario ${video.status.lastError}',
        );
      } catch (_) {
        stderr.writeln(
          await remote.evaluate(
            'JSON.stringify({pixels:[window.__remote?.videoView.video.videoWidth,window.__remote?.videoView.video.videoHeight],layout:[window.__remote?.videoView.viewportWidth,window.__remote?.videoView.viewportHeight,window.__remote?.videoView.deviceScaleFactor],error:window.__remote?.videoView.lastError,stage:[document.getElementById("stage-video").clientWidth,document.getElementById("stage-video").clientHeight]})',
          ),
        );
        stderr.writeln(
          'PIPELINE: ${video.status.lastError} CAPTURE: $lastMeta',
        );
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (var i = 0; i < 30; i++) {
        if (i == 10) {
          // 用户切换帧率会重新截图并重启采集；新流仍须保持正确比例。
          final streamId = await remote.evaluate(
            'window.__remote.videoView._streamId',
          );
          await remote.evaluate('window.__remote.client.setFrameRate(15)');
          await wait(
            () async =>
                await remote.evaluate('window.__remote.videoView._streamId') !=
                streamId,
            '切换帧率未重启视频流',
          );
          await wait(
            () => remote.evaluate<bool>(
              '(() => {const v=window.__remote.videoView;return !!v._mse?.sourceBuffer && v.video.readyState>=2 && v.video.currentTime>0.05 && v.video.currentSrc===v.video.src && v.video.videoWidth>0;})()',
            ),
            '重启后视频未恢复',
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (i == 20) {
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
        final color = i.isEven ? '#ff00ff' : '#00ffff';
        await page.evaluate(
          "document.getElementById('center').style.background='$color'",
        );
        var fresh = false;
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 33));
          final raw = await remote.evaluate(
            'JSON.stringify(($_samplePixels)(window.__remote.videoView.video))',
          ) as String;
          final result = jsonDecode(raw) as Map;
          if (result['corners'] != true) {
            await File('/private/tmp/gci-video-geometry-$zoom.png')
                .writeAsBytes(await remote.screenshot());
            stderr.writeln('FAIL $scenario frame=$i $raw');
            stderr.writeln(
              'SOURCE ${await page.evaluate('JSON.stringify({width:innerWidth,height:innerHeight,dpr:devicePixelRatio,visual:[visualViewport.width,visualViewport.height,visualViewport.scale],screen:[screen.width,screen.height]})')} CAPTURE_META $lastMeta',
            );
            if (lastCapture != null) {
              stderr.writeln(
                'CAPTURE ${await remote.evaluate("(async()=>{const im=new Image();im.src='data:image/jpeg;base64,$lastCapture';await im.decode();return JSON.stringify(($_samplePixels)(im));})()")}',
              );
            }
            throw StateError('视频四角不完整，内容被裁切或缩放错误');
          }
          final center = (result['colors'] as List)[4] as List;
          if (i.isEven
              ? center[0] > 175 && center[1] < 80 && center[2] > 175
              : center[0] < 80 && center[1] > 175 && center[2] > 175) {
            fresh = true;
            break;
          }
        }
        if (!fresh) {
          stderr.writeln(
            await remote.evaluate(
              'JSON.stringify({time:window.__remote.videoView.video.currentTime,error:window.__remote.videoView.video.error?.message,aus:window.__remote.videoView.ausReceived,buffer:Array.from({length:window.__remote.videoView.video.buffered.length},(_,i)=>[window.__remote.videoView.video.buffered.start(i),window.__remote.videoView.video.buffered.end(i)])})',
            ),
          );
          stderr.writeln(
            'ENCODE: ${video.status.framesEncoded}/${video.status.ausSent} META: $lastMeta',
          );
          if (lastCapture != null) {
            stderr.writeln(
              'CAPTURE ${await remote.evaluate("(async()=>{const im=new Image();im.src='data:image/jpeg;base64,$lastCapture';await im.decode();return JSON.stringify(($_samplePixels)(im));})()")}',
            );
          }
          throw StateError(
            '视频未呈现新画面: $scenario frame=$i ${video.status.lastError}',
          );
        }
      }
      if (lastCapture == null) throw StateError('没有收到实时采集帧');
      final capture = jsonDecode(
        await remote.evaluate(
          "(async()=>{const im=new Image();im.src='data:image/jpeg;base64,$lastCapture';await im.decode();return JSON.stringify(($_samplePixels)(im));})()",
        ) as String,
      ) as Map;
      final stage = jsonDecode(
        await remote.evaluate(
          "JSON.stringify([document.getElementById('stage-video').clientWidth,document.getElementById('stage-video').clientHeight])",
        ) as String,
      ) as List;
      final pixels = capture['pixels'] as List;
      // 原始表面换算和 YUV 采样各有一次舍入；仍须达到手机像素密度。
      if (capture['corners'] != true ||
          ((pixels[0] as num) - (stage[0] as num) * dpr).abs() > 4 ||
          ((pixels[1] as num) - (stage[1] as num) * dpr).abs() > 4) {
        throw StateError('原始采集帧不完整或分辨率不足: $scenario $capture');
      }
      await page.evaluate('window.__corner=null');
      final rect = jsonDecode(
        await remote.evaluate(
          "JSON.stringify(window.__remote.videoView.video.getBoundingClientRect())",
        ) as String,
      ) as Map;
      await remote.touchscreen.tap(
        pp.Point(
          (rect['left'] as num) + (rect['width'] as num) * .97,
          (rect['top'] as num) + (rect['height'] as num) * .97,
        ),
      );
      await wait(
        () async => await page.evaluate('window.__corner') == 'br',
        '右下角视觉位置与点击位置不一致',
      );
      stdout.writeln(
        'PASS $scenario: 30 fresh frames include all corners; bottom-right click matches displayed content.',
      );
    }
  } finally {
    await frameSub?.cancel();
    await video?.stop();
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
