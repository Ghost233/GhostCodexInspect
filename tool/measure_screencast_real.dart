// 真机画面流带宽采样（工单 #21 调研数据）：静置 vs 局部变化两种场景。
//
// attach 9238 → 主 shell → startScreencast(q60, everyNthFrame=1)：
// 场景 A 静置 10s（CDP 只在画面变化出帧——验证「完全重刷」的真实频率）；
// 场景 B 注入局部闪烁元素 10s（局部变化场景：观察是否仍每帧全量 JPEG）。
// 结束后清理注入元素。全程不改页面内容（闪烁元素用完即删）。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/measure_screencast_real.dart
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';

const debugPort = 9238;
const phaseSeconds = 10;

void step(String message) => stdout.writeln('\n=== $message');

Future<(int, int)> sample(CdpPage page, String label) async {
  var frames = 0;
  var bytes = 0;
  final sub = page.screencastFrames.listen((f) {
    frames++;
    bytes += f.data.length; // base64 长度 ≈ 导线成本（×3/4 为原始字节）
    unawaited(page.send('Page.screencastFrameAck', {'sessionId': f.sessionId}));
  });
  await Future<void>.delayed(const Duration(seconds: phaseSeconds));
  await sub.cancel();
  stdout.writeln(
    '$label：$frames 帧 / $bytes B（base64）'
    ' ≈ ${(bytes / phaseSeconds / 1024).toStringAsFixed(1)} KB/s',
  );
  return (frames, bytes);
}

Future<void> main() async {
  final connection = await connectCdp(debugPort: debugPort);
  final targets = await connection.client.listTargets();
  final shells = targets
      .where((t) => t.type == 'page' && t.url.startsWith('app://'))
      .toList();
  final shell = shells.firstWhere(
    (t) => !Uri.parse(t.url).queryParameters.containsKey('initialRoute'),
    orElse: () => throw StateError('无主 shell：$shells'),
  );
  stdout.writeln('主 shell：${shell.url}');
  final page = await connection.client.attachTo(shell);

  try {
    await page.send('Page.enable');
    await page.send('Page.startScreencast', {
      'format': 'jpeg',
      'quality': 60,
      'everyNthFrame': 1,
    });

    step('场景 A：页面静置 $phaseSeconds s');
    final (idleFrames, idleBytes) = await sample(page, 'A 静置');

    step('场景 B：局部闪烁（200×100 元素 500ms 变色）$phaseSeconds s');
    await page.evaluate('''
(function () {
  const d = document.createElement('div');
  d.id = '__gciBlink';
  d.style.cssText = 'position:fixed;left:0;top:0;width:200px;height:100px;'
      + 'z-index:2147483647;pointer-events:none;';
  document.body.appendChild(d);
  let on = false;
  window.__gciBlinkTimer = setInterval(() => {
    on = !on;
    d.style.background = on ? '#0af' : '#fa0';
  }, 500);
})()
''');
    final (blinkFrames, blinkBytes) = await sample(page, 'B 局部闪烁');

    await page.evaluate('''
(function () {
  clearInterval(window.__gciBlinkTimer);
  const d = document.getElementById('__gciBlink');
  if (d) d.remove();
})()
''');

    await page.send('Page.stopScreencast');

    final report = StringBuffer()
      ..writeln('# 画面流带宽真机采样（#21）')
      ..writeln()
      ..writeln('- 时间：${DateTime.now().toLocal()}')
      ..writeln('- 目标：ChatGPT.app 主 shell，startScreencast q60 everyNthFrame=1')
      ..writeln('- 字节数为 base64 导线长度（原始字节 ×3/4）')
      ..writeln()
      ..writeln('| 场景 | 帧数（${phaseSeconds}s） | 字节 | 平均带宽 |')
      ..writeln('|------|------|------|------|')
      ..writeln(
        '| A 静置 | $idleFrames | $idleBytes B | '
        '${(idleBytes / phaseSeconds / 1024).toStringAsFixed(1)} KB/s |',
      )
      ..writeln(
        '| B 局部闪烁 | $blinkFrames | $blinkBytes B | '
        '${(blinkBytes / phaseSeconds / 1024).toStringAsFixed(1)} KB/s |',
      );
    final ts = DateTime.now()
        .toLocal()
        .toString()
        .replaceAll(RegExp('[^0-9]'), '')
        .substring(0, 14);
    final path = 'docs/research/screencast-bandwidth-$ts.md';
    await File(path).writeAsString(report.toString());
    stdout.writeln('\n报告：$path');
  } finally {
    await connection.client.close();
  }
}
