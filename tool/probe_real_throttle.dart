// Bug 1 机制验证：真实 Codex 页（9238）后台/遮挡节流是否导致截帧断流，
// 以及 Emulation.setFocusEmulationEnabled 能否解除。
//
// 流程：注入脉冲点（验证注入成功）→ 基线 10s 截帧计数 → 开焦点仿真 →
// 再测 10s → 关焦点仿真。只读页面状态，不改视口覆盖。
//
// 用法：`dart run tool/probe_real_throttle.dart`

import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';

void log(String msg) => stderr.writeln('[probe-throttle] $msg');

Future<int> countFrames(CdpPage page, Duration window) async {
  var n = 0;
  final sub = page.screencastFrames.listen((f) {
    n++;
    unawaited(
      page
          .send('Page.screencastFrameAck', {'sessionId': f.sessionId})
          .catchError((_) => <String, dynamic>{}),
    );
  });
  await page.send('Page.startScreencast', {
    'format': 'jpeg',
    'quality': 60,
    'everyNthFrame': 2,
  });
  await Future<void>.delayed(window);
  await page.send('Page.stopScreencast');
  await sub.cancel();
  return n;
}

Future<void> main() async {
  final connection = await connectCdp(debugPort: 9238, preferRaw: false);
  try {
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['app', 'file']);
    final page = await connection.client.attachTo(shell);
    log('目标=${shell.url}');
    log(
      '视口=${await page.evaluate('innerWidth')}x${await page.evaluate('innerHeight')} '
      'dpr=${await page.evaluate('devicePixelRatio')} '
      'visibility=${await page.evaluate('document.visibilityState')} '
      'focus=${await page.evaluate('document.hasFocus()')}',
    );

    // 注入脉冲点并验证（rAF 驱动 + setInterval 兜底，各记计数）
    final injected = await page.evaluate('''
      (function(){
        if (!document.body) return 'no-body';
        const old = document.getElementById('__gciPulse');
        if (old) old.remove();
        const d = document.createElement('div');
        d.id = '__gciPulse';
        d.style.cssText = 'position:fixed;left:2px;top:2px;width:6px;height:6px;'
          + 'border-radius:3px;background:#f0f;z-index:2147483647;pointer-events:none;';
        document.documentElement.appendChild(d);
        window.__pulseRaf = 0; window.__pulseTimer = 0;
        (function tick(){ window.__pulseRaf++;
          d.style.opacity = (window.__pulseRaf % 2) ? '1' : '0.15';
          requestAnimationFrame(tick); })();
        setInterval(() => { window.__pulseTimer++;
          d.style.background = (window.__pulseTimer % 2) ? '#f0f' : '#0ff'; }, 100);
        return 'ok';
      })()
    ''');
    log('脉冲点注入=$injected');

    final base = await countFrames(page, const Duration(seconds: 10));
    final raf1 = await page.evaluate('window.__pulseRaf');
    final tim1 = await page.evaluate('window.__pulseTimer');
    log('基线 10s：帧=$base rAF计数=$raf1 interval计数=$tim1');

    await page.send('Emulation.setFocusEmulationEnabled', {'enabled': true});
    log('已开 Emulation.setFocusEmulationEnabled(true)');
    final withFocus = await countFrames(page, const Duration(seconds: 10));
    final raf2 = await page.evaluate('window.__pulseRaf');
    log('焦点仿真 10s：帧=$withFocus rAF增量=${(raf2 as num) - (raf1 as num)}');

    await page.send('Emulation.setFocusEmulationEnabled', {'enabled': false});
    await page.evaluate(
      "(()=>{const d=document.getElementById('__gciPulse'); if(d) d.remove(); return 1;})()",
    );
    log('已恢复（焦点仿真关闭、脉冲点移除）');

    if (base == 0 && withFocus > base) {
      log('✅ 机制确认：遮挡/后台节流致断流，焦点仿真可解除');
    } else if (base == 0 && withFocus == 0) {
      log('⚠️ 断流确认，但焦点仿真无效——需另找解除手段或做 UX 明示');
    } else {
      log('ℹ️ 基线有帧（$base）：当前未处于节流状态');
    }
  } finally {
    await connection.client.close();
  }
}
