// 真机视口覆盖探针（2026-10-19，bug 2 诊断）。
//
// 用法：`dart run tool/repro_real_viewport.dart`（需 ChatGPT.app 已带
// --remote-debugging-port=9238 运行）。
//
// 只做三件事：读当前视口 → 应用 1000x700 设备指标覆盖再读 → 清除覆盖
// 并确认恢复。用于判定真实 Codex 页面是否接受
// Emulation.setDeviceMetricsOverride（fixture 已验接受，真机未验）。

import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/cdp/viewport_override.dart';

void log(String msg) => stderr.writeln('[real-viewport] $msg');

Future<void> main() async {
  final connection = await connectCdp(debugPort: 9238, preferRaw: false);
  try {
    final targets = await connection.client.listTargets();
    final shell = findShellTarget(targets, const ['app', 'file']);
    log('shell=${shell.url} title=${shell.title}');
    final page = await connection.client.attachTo(shell);

    Future<String> read() async {
      final v = await page.evaluate(
        'JSON.stringify({iw: innerWidth, ih: innerHeight, ow: outerWidth, oh: outerHeight, dpr: devicePixelRatio})',
      );
      return v as String;
    }

    log('覆盖前：${await read()}');
    await applyViewportOverride(page, 1000, 700);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final during = await read();
    log('覆盖 1000x700 后：$during');
    final ok = during.contains('"iw":1000') && during.contains('"ih":700');
    await clearViewportOverride(page);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    log('清除覆盖后：${await read()}');
    log(ok ? '✅ 真实页面接受视口覆盖' : '❌ 真实页面不接受视口覆盖');
    exitCode = ok ? 0 : 1;
  } finally {
    await connection.client.close();
  }
}
