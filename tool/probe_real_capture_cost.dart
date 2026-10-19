// Bug 1 测量探针（真机版）：真实 Codex 页（9238）上 CDP screencast 的
// 采集成本——帧像素尺寸（dpr 是否放大）、JPEG 字节数、到达帧率，q90/q60
// 对照。只读测量：不改视口覆盖、不动 live 会话；页面注入一枚 6px 角落
// 脉冲点驱动截帧（12s 后自动移除，几乎不可见）。
//
// 用法：`dart run tool/probe_real_capture_cost.dart [quality]`

import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';

void log(String msg) => stderr.writeln('[probe-capture] $msg');

Future<void> main(List<String> args) async {
  final quality = args.isNotEmpty ? int.parse(args[0]) : 90;

  final connection = await connectCdp(debugPort: 9238, preferRaw: false);
  try {
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['app', 'file']);
    log('目标=${shell.url}');
    final page = await connection.client.attachTo(shell);
    log(
      '视口=${await page.evaluate('innerWidth')}x${await page.evaluate('innerHeight')} '
      'dpr=${await page.evaluate('devicePixelRatio')}',
    );

    // 角落脉冲点驱动截帧（12s 自动移除）
    await page.evaluate('''
      (function(){
        if (document.getElementById('__gciPulse')) return;
        const d = document.createElement('div');
        d.id = '__gciPulse';
        d.style.cssText = 'position:fixed;left:2px;top:2px;width:6px;height:6px;'
          + 'border-radius:3px;background:#f0f;z-index:2147483647;pointer-events:none;';
        document.documentElement.appendChild(d);
        let on = false;
        d.__timer = setInterval(() => { on = !on; d.style.opacity = on ? '1' : '0.15'; }, 50);
        setTimeout(() => { clearInterval(d.__timer); d.remove(); }, 20000);
      })()
    ''');

    final frames = <Map<String, dynamic>>[];
    final sub = page.screencastFrames.listen((f) {
      unawaited(
        page
            .send('Page.screencastFrameAck', {'sessionId': f.sessionId})
            .catchError((_) => <String, dynamic>{}),
      );
      frames.add({
        't': DateTime.now().millisecondsSinceEpoch,
        'bytes': (f.data.length * 3 / 4).round(), // base64→原始字节
        'dw': f.metadata['deviceWidth'],
        'dh': f.metadata['deviceHeight'],
        'ts': f.metadata['timestamp'],
      });
    });
    await page.send('Page.startScreencast', {
      'format': 'jpeg',
      'quality': quality,
      'everyNthFrame': 2,
    });
    await Future<void>.delayed(const Duration(seconds: 12));
    await page.send('Page.stopScreencast');
    await sub.cancel();

    if (frames.isEmpty) {
      log('❌ 12s 无帧（页面完全静止？脉冲点未生效）');
      exitCode = 1;
      return;
    }
    final t0 = frames.first['t'] as int;
    final t1 = frames.last['t'] as int;
    final secs = (t1 - t0) / 1000;
    final sizes = frames.map((f) => f['bytes'] as int).toList()..sort();
    final arrivalGap = <int>[
      for (var i = 1; i < frames.length; i++)
        (frames[i]['t'] as int) - (frames[i - 1]['t'] as int),
    ]..sort();
    final withTs = frames.where((f) => f['ts'] is num).length;
    // 采集→到达 Dart 的延迟
    final ages = <double>[
      for (final f in frames)
        if (f['ts'] is num)
          ((f['t'] as int) / 1000 - (f['ts'] as num).toDouble()) * 1000,
    ]..sort();
    log(
      'quality=$quality 帧数=${frames.length} 时长=${secs.toStringAsFixed(1)}s '
      'fps=${(frames.length / secs).toStringAsFixed(1)}',
    );
    log(
      '帧像素=${frames.last['dw']}x${frames.last['dh']} '
      'JPEG字节 p50=${sizes[sizes.length ~/ 2]} '
      'p95=${sizes[(sizes.length * 95) ~/ 100]} max=${sizes.last}',
    );
    log(
      '到达间隔ms p50=${arrivalGap[arrivalGap.length ~/ 2]} '
      'p95=${arrivalGap[(arrivalGap.length * 95) ~/ 100]} max=${arrivalGap.last}',
    );
    if (ages.isNotEmpty) {
      log(
        '采集→宿主延迟ms p50=${ages[ages.length ~/ 2].toStringAsFixed(0)} '
        'p95=${ages[(ages.length * 95) ~/ 100].toStringAsFixed(0)} '
        'max=${ages.last.toStringAsFixed(0)}（含时间戳帧 $withTs/${frames.length}）',
      );
    } else {
      log('⚠️ 帧元数据无 timestamp 字段（$withTs/${frames.length}）');
    }
  } finally {
    await connection.client.close();
  }
}
