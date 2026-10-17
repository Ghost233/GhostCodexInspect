// 一次性真机实测探针（工单 #4/#6 的「只能启动一次」适配）。
//
// 用户约束：ChatGPT.app 只能带参重启一次，不能反复启动。本脚本因此设计为
// **attach 已运行实例、一遍采全 #4/#6 所需全部数据**，可重复运行（attach
// 不需要重启目标）。
//
// 探针清单（每个独立 try/catch，单项失败不中断后续）：
//   1. preflight        前提校验复跑（版本漂移对比 #2 快照）
//   2. connect          CDP 连接（puppeteer 优先，raw 回退）
//   3. targets          target 枚举与 shell 分类
//   4. shellReadOnly    shell 页只读勘察：URL/UA/样式表 CSSOM 可访问性
//                       （app:// CSP 疑问，#3 遗留）/CSP meta/iframe/canvas
//   5. injection        注入可行性：addScriptToEvaluateOnNewDocument 收发
//                       identifier + Runtime.addBinding 回传（均带清理）
//   6. input            Input.insertText 兼容性（离屏临时 input，不碰真实 UI）；
//                       dispatchMouseEvent 仅 fixture 模式测（真实 UI 点击太危险，
//                       fixture 已证明，见 #11/#12）
//   7. rrwebDryRun      rrweb record 干跑 3s：事件数/字节量/全量快照大小
//                       （页内统计，带 stop 清理，不持久化任何 DOM 内容）
//   8. screencast       startScreencast 带宽实测：q60 5s + q40/q80 各 2s，
//                       只记帧长不存图（隐私），ack 流控
//   9. screenshot       captureScreenshot 单帧延迟与大小（备选方案校准）
//
// 运行（仓库根目录）：
//   真机（目标已带 --remote-debugging-port=9238 运行）：
//     /Users/ghost233/flutter/bin/dart run tool/real_machine_probe.dart
//   fixture 自检（脚本自己拉起/停止 fixture）：
//     /Users/ghost233/flutter/bin/dart run tool/real_machine_probe.dart --fixture
//
// 报告写入 docs/research/real-probe-<时间戳>.md 并打印摘要。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom_collector.dart';
import 'package:ghost_codex_inspect/inspector/inspector.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';

class ProbeResult {
  ProbeResult(this.name);
  final String name;
  bool? passed;
  String detail = '';
  final Map<String, Object?> metrics = {};
}

void step(String message) => stdout.writeln('\n=== $message');

Future<void> runProbe(
  String name,
  ProbeResult result,
  Future<void> Function() body,
) async {
  step('探针：$name');
  try {
    await body();
    result.passed ??= true;
  } catch (e) {
    result.passed = false;
    result.detail = '$e';
    stderr.writeln('  失败：$e');
  }
  if (result.passed == true && result.detail.isNotEmpty) {
    stdout.writeln('  ${result.detail}');
  }
}

Future<void> main(List<String> args) async {
  final fixtureMode = args.contains('--fixture');
  var portArg = '';
  for (final a in args) {
    if (a.startsWith('--port=')) portArg = a.substring('--port='.length);
  }
  final debugPort = int.tryParse(portArg) ?? 9238;

  final repoRoot = Directory.current.path;
  final fixtureDir = '$repoRoot/tool/fixture';
  final profile = fixtureMode
      ? TargetProfile.electronFixture(
          electronAppPath: '$fixtureDir/node_modules/electron/dist/Electron.app',
          fixtureDir: fixtureDir,
        )
      : TargetProfile.chatGpt;

  final results = <ProbeResult>[];
  final launcher = AppLauncher();
  var fixtureLaunched = false;

  if (fixtureMode) {
    step('fixture 模式：先拉起 fixture（端口 $debugPort）');
    await launcher.launch(profile, debugPort: debugPort);
    fixtureLaunched = true;
  }

  CdpConnection? connection;
  CdpPage? shellPage;

  try {
    // ---- 1. preflight ----
    final preflightR = ProbeResult('preflight');
    results.add(preflightR);
    await runProbe('preflight', preflightR, () async {
      final report = await Inspector().checkPreflight(profile);
      preflightR.metrics['passed'] = report.passed;
      preflightR.metrics['version'] = report.inspection.version;
      preflightR.metrics['buildNumber'] = report.inspection.buildNumber;
      preflightR.metrics['hardenedRuntime'] =
          report.inspection.signature.hardenedRuntime;
      if (!report.passed) {
        preflightR.passed = false;
        preflightR.detail = '前提校验未通过：${report.toPrettyJson()}';
        return;
      }
      preflightR.detail =
          '版本 ${report.inspection.version}（build ${report.inspection.buildNumber}），'
          'hardened runtime=${report.inspection.signature.hardenedRuntime}';
    });

    // ---- 2. connect ----
    final connectR = ProbeResult('connect');
    results.add(connectR);
    await runProbe('connect', connectR, () async {
      connection = await connectCdp(debugPort: debugPort);
      connectR.metrics['implementation'] = connection!.implementationName;
      connectR.metrics['fellBack'] = connection!.fellBack;
      connectR.detail =
          '实现 ${connection!.implementationName}'
          '${connection!.fellBack ? '（puppeteer 失败回退：${connection!.puppeteerError}）' : ''}';
    });
    if (connection == null) {
      throw StateError('CDP 连接失败，后续探针无法执行。确认目标已带 '
          '--remote-debugging-port=$debugPort 运行。');
    }

    // ---- 3. targets ----
    final targetsR = ProbeResult('targets');
    results.add(targetsR);
    final shellTargets = <CdpTargetInfo>[];
    await runProbe('targets', targetsR, () async {
      final targets = await connection!.client.listTargets();
      final byType = <String, int>{};
      for (final t in targets) {
        byType[t.type] = (byType[t.type] ?? 0) + 1;
      }
      for (final t in targets) {
        final isShell = t.type == 'page' &&
            profile.shellUrlSchemes.any((s) => t.url.startsWith('$s://'));
        if (isShell) shellTargets.add(t);
        stdout.writeln(
          '  ${isShell ? '[shell]' : '      '} ${t.type} ${t.url}',
        );
      }
      targetsR.metrics['total'] = targets.length;
      targetsR.metrics['byType'] = byType.toString();
      targetsR.metrics['shellCount'] = shellTargets.length;
      if (shellTargets.isEmpty) {
        targetsR.passed = false;
        targetsR.detail = '未找到 shell 页面（scheme：'
            '${profile.shellUrlSchemes.join(', ')}）。真实应用的 shell URL '
            'scheme 可能与 #2 记录不符——把上面枚举输出贴进 #4。';
        return;
      }
      targetsR.detail = '${targets.length} 个 target，shell 命中 '
          '${shellTargets.length} 个';
    });
    if (shellTargets.isEmpty) {
      throw StateError('无 shell 页面，后续探针终止。');
    }

    shellPage = await connection!.client.attachTo(shellTargets.first);
    final page = shellPage;

    // ---- 4. shellReadOnly ----
    final shellR = ProbeResult('shellReadOnly');
    results.add(shellR);
    await runProbe('shellReadOnly', shellR, () async {
      final bundle = await page.evaluate(r'''
JSON.stringify({
  href: location.href,
  title: document.title,
  ua: navigator.userAgent,
  viewport: [window.innerWidth, window.innerHeight],
  dpr: window.devicePixelRatio,
  styleSheets: Array.from(document.styleSheets).map(function (s) {
    try { return s.cssRules.length; } catch (e) { return 'BLOCKED:' + e.name; }
  }),
  cspMeta: (function () {
    var m = document.querySelector('meta[http-equiv="Content-Security-Policy"]');
    return m ? m.content : null;
  })(),
  iframes: Array.from(document.querySelectorAll('iframe')).map(function (f) {
    return f.src || '(no-src)';
  }),
  canvasCount: document.querySelectorAll('canvas').length,
})
''');
      shellR.detail = '$bundle';
      shellR.metrics['raw'] = bundle;
      stdout.writeln('  $bundle');
    });

    // ---- 5. injection ----
    final injectR = ProbeResult('injection');
    results.add(injectR);
    await runProbe('injection', injectR, () async {
      await page.send('Page.enable');
      // addScriptToEvaluateOnNewDocument：只验证受理与 identifier 回收，不导航。
      final added = await page.send('Page.addScriptToEvaluateOnNewDocument', {
        'source': 'window.__gciProbeMarker = 1;',
      });
      final identifier = added['identifier'];
      injectR.metrics['addScriptIdentifier'] = identifier;
      if (identifier == null) {
        throw StateError('addScriptToEvaluateOnNewDocument 未返回 identifier');
      }
      await page.send('Page.removeScriptToEvaluateOnNewDocument', {
        'identifier': identifier,
      });

      // Runtime.addBinding：页面侧调用 → 宿主收到 payload。
      final bindingStream = await page.exposeBinding('__gciProbeBinding');
      final received = Completer<String>();
      final sub = bindingStream.listen(received.complete);
      await page.evaluate("window.__gciProbeBinding('ping')");
      final payload =
          await received.future.timeout(const Duration(seconds: 5));
      await sub.cancel();
      await page.send('Runtime.removeBinding', {'name': '__gciProbeBinding'});
      injectR.metrics['bindingPayload'] = payload;
      if (payload != 'ping') {
        throw StateError('binding 回传不符：$payload');
      }
      injectR.detail = 'addScript identifier=$identifier（已回收），binding 回传 OK';
    });

    // ---- 6. input ----
    final inputR = ProbeResult('input');
    results.add(inputR);
    await runProbe('input', inputR, () async {
      // insertText：离屏临时 input，不触碰真实 UI。
      await page.evaluate(r'''
;(function () {
  var el = document.createElement('input');
  el.id = '__gciProbeInput';
  el.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0;';
  document.body.appendChild(el);
  el.focus();
})();
''');
      await page.send('Input.insertText', {'text': 'probe'});
      final value = await page
          .evaluate("document.getElementById('__gciProbeInput').value");
      await page.evaluate(
        "document.getElementById('__gciProbeInput').remove()",
      );
      inputR.metrics['insertTextResult'] = value;
      if (value != 'probe') {
        throw StateError('insertText 未生效（读到：$value）');
      }

      if (fixtureMode) {
        // dispatchMouseEvent：只在 fixture 上测（fixture 按钮无副作用）。
        final rect = await page.evaluate(r'''
JSON.stringify((function () {
  var r = document.getElementById('counter-btn').getBoundingClientRect();
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
})());
''');
        final xy = (rect as String)
            .replaceAll(RegExp(r'[{}"]'), '')
            .split(',')
            .map((s) => double.parse(s.split(':')[1]))
            .toList();
        for (final type in ['mousePressed', 'mouseReleased']) {
          await page.send('Input.dispatchMouseEvent', {
            'type': type,
            'x': xy[0],
            'y': xy[1],
            'button': 'left',
            'clickCount': 1,
          });
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final title = await page.evaluate('document.title');
        inputR.metrics['clickTitle'] = title;
        if ('$title'.contains('clicks=0')) {
          throw StateError('点击未回灌（title=$title）');
        }
        inputR.detail = 'insertText OK；fixture 点击回灌 OK（$title）';
      } else {
        inputR.detail = 'insertText OK；dispatchMouseEvent 真机跳过'
            '（点击真实 UI 太危险，fixture 已证明，见 #11/#12）';
      }
    });

    // ---- 7. rrwebDryRun ----
    final rrwebR = ProbeResult('rrwebDryRun');
    results.add(rrwebR);
    await runProbe('rrwebDryRun', rrwebR, () async {
      // 用与采集器相同的剥离规则处理 record 源码，但换成带 stop 句柄的
      // 页内统计包装（不经过 __gciEmit binding，不持久化任何 DOM 内容）。
      final collector = await loadCollectorSource();
      final stripped = collector.endsWith(kCollectorGlue)
          ? collector.substring(0, collector.length - kCollectorGlue.length)
          : throw StateError('采集器源码结构变化，无法分离 record 部分');
      await page.evaluate('''
$stripped
;(function () {
  window.__gciProbeStats = { n: 0, bytes: 0, full: 0, fullBytes: 0 };
  window.__gciProbeStop = record({
    emit: function (ev) {
      var s = window.__gciProbeStats;
      var len = JSON.stringify(ev).length;
      s.n++; s.bytes += len;
      if (ev.type === 2) { s.full++; s.fullBytes += len; }
    },
  });
})();
''');
      // fixture 模式下点一下按钮制造增量事件。
      if (fixtureMode) {
        await page.evaluate(
          "document.getElementById('counter-btn').click()",
        );
      }
      await Future<void>.delayed(const Duration(seconds: 3));
      final stats = await page.evaluate(
        'JSON.stringify(window.__gciProbeStats)',
      );
      await page.evaluate(r'''
;(function () {
  if (window.__gciProbeStop) window.__gciProbeStop();
  delete window.__gciProbeStop;
  delete window.__gciProbeStats;
})();
''');
      rrwebR.metrics['stats'] = stats;
      rrwebR.detail = '3s 统计：$stats';
      stdout.writeln('  $stats');
      if ('$stats'.contains('"n":0')) {
        throw StateError('record 未产出任何事件');
      }
    });

    // ---- 8. screencast 带宽 ----
    final castR = ProbeResult('screencast');
    results.add(castR);
    await runProbe('screencast', castR, () async {
      await page.send('Page.enable');
      // fixture 的开场动画只播 3s，到本探针时已静止（screencast 只在画面
      // 变化时出帧）；fixture 模式下手动起动画让帧率测量有意义。
      if (fixtureMode) {
        await page.evaluate(r'''
window.__gciProbeAnim = setInterval(function () {
  document.body.style.filter = document.body.style.filter ? '' : 'invert(1)';
}, 100);
''');
      }
      final frames = <ScreencastFrameData>[];
      final sub = page.screencastFrames.listen((f) {
        frames.add(f);
        unawaited(
          page.send('Page.screencastFrameAck', {'sessionId': f.sessionId})
              .catchError((Object _) => <String, dynamic>{}),
        );
      });

      Future<Map<String, Object?>> measure(int quality, int seconds) async {
        frames.clear();
        await page.send('Page.startScreencast', {
          'format': 'jpeg',
          'quality': quality,
          'everyNthFrame': 1,
        });
        await Future<void>.delayed(Duration(seconds: seconds));
        await page.send('Page.stopScreencast');
        // base64 长度 ×0.75 ≈ 原始字节
        final bytes = frames.fold<int>(0, (s, f) => s + f.data.length) * 3 ~/ 4;
        return {
          'quality': quality,
          'seconds': seconds,
          'frames': frames.length,
          'fps': (frames.length / seconds).toStringAsFixed(1),
          'kbps': (bytes / seconds / 1024).toStringAsFixed(0),
          'avgFrameBytes': frames.isEmpty ? 0 : bytes ~/ frames.length,
        };
      }

      final q60 = await measure(60, 5);
      final q40 = await measure(40, 2);
      final q80 = await measure(80, 2);
      await sub.cancel();
      if (fixtureMode) {
        await page.evaluate('clearInterval(window.__gciProbeAnim)');
      }
      castR.metrics['q60'] = q60;
      castR.metrics['q40'] = q40;
      castR.metrics['q80'] = q80;
      castR.detail = 'q60: ${q60['fps']}fps ${q60['kbps']}KB/s；'
          'q40: ${q40['kbps']}KB/s；q80: ${q80['kbps']}KB/s';
      stdout.writeln('  q60=$q60\n  q40=$q40\n  q80=$q80');
      if ((q60['frames'] as int) == 0) {
        throw StateError('5s 内未收到任何 screencast 帧');
      }
    });

    // ---- 9. captureScreenshot 备选校准 ----
    final shotR = ProbeResult('screenshot');
    results.add(shotR);
    await runProbe('screenshot', shotR, () async {
      final sw = Stopwatch()..start();
      final shot = await page.send('Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': 60,
      });
      sw.stop();
      final data = shot['data'] as String? ?? '';
      shotR.metrics['latencyMs'] = sw.elapsedMilliseconds;
      shotR.metrics['bytes'] = data.length * 3 ~/ 4;
      shotR.detail = '延迟 ${sw.elapsedMilliseconds}ms，'
          '约 ${data.length * 3 ~/ 4 ~/ 1024}KB（数据已丢弃，未持久化）';
    });
  } finally {
    await shellPage?.close();
    await connection?.client.close();
    if (fixtureLaunched) {
      step('清理：停止 fixture');
      await launcher.stop(profile);
    }
  }

  // ---- 报告 ----
  final now = DateTime.now();
  final ts = '${now.year}${now.month.toString().padLeft(2, '0')}'
      '${now.day.toString().padLeft(2, '0')}-'
      '${now.hour.toString().padLeft(2, '0')}'
      '${now.minute.toString().padLeft(2, '0')}'
      '${now.second.toString().padLeft(2, '0')}';
  final buffer = StringBuffer()
    ..writeln('# 一次性真机实测探针报告（#$ts）')
    ..writeln()
    ..writeln('- 目标：${profile.displayName}（${profile.appPath}）')
    ..writeln('- 模式：${fixtureMode ? 'fixture 自检' : '真机 attach（只读+自清理注入，未重启目标）'}')
    ..writeln('- 调试端口：$debugPort')
    ..writeln()
    ..writeln('| 探针 | 结果 | 说明 |')
    ..writeln('|---|---|---|');
  var failed = false;
  for (final r in results) {
    final mark = r.passed == true ? '✅' : '❌';
    if (r.passed != true) failed = true;
    buffer.writeln('| ${r.name} | $mark | ${r.detail.replaceAll('|', '\\|')} |');
  }
  buffer
    ..writeln()
    ..writeln('## 指标明细')
    ..writeln();
  for (final r in results) {
    if (r.metrics.isEmpty) continue;
    buffer.writeln('### ${r.name}');
    r.metrics.forEach((k, v) => buffer.writeln('- `$k`: $v'));
    buffer.writeln();
  }
  final reportPath = 'docs/research/real-probe-$ts.md';
  File(reportPath).writeAsStringSync(buffer.toString());

  step('报告已写入 $reportPath');
  final passCount = results.where((r) => r.passed == true).length;
  stdout.writeln('探针通过 $passCount/${results.length}');
  if (failed) exitCode = 1;
}
