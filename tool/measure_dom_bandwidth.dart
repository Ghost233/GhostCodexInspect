// 真机 DOM 重绘带宽实测（工单 #18 Scope 1，只读）。
//
// attach 9238 → 主 shell → DomSession（默认压缩阈值）→ 一个无 caps 的
// Dart WS 客户端（等价旧版远程端，收文本帧）统计 30 秒导线字节：
// 压缩后全量快照的实际成本 + 稳态增量速率。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/measure_dom_bandwidth.dart
//
// 前置：ChatGPT.app 带参运行中（127.0.0.1:9238）。全程只读，不动目标进程。
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/dom/dom.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const debugPort = 9238;
const sampleSeconds = 30;

void step(String message) => stdout.writeln('\n=== $message');

Future<void> main() async {
  final launcher = AppLauncher();
  if (!await launcher.isDebugPortAlive(debugPort)) {
    stderr.writeln('调试端口 $debugPort 未监听：请先带参启动目标应用。');
    exitCode = 2;
    return;
  }

  step('1/4 CDP attach + 定位主 shell 页面');
  final connection = await connectCdp(debugPort: debugPort);
  stdout.writeln('CDP 实现：${connection.implementationName}');
  final shell = findShellTarget(
    await connection.client.listTargets(),
    TargetProfile.chatGpt.shellUrlSchemes,
  );
  stdout.writeln('主 shell：${shell.url}');
  final page = await connection.client.attachTo(shell);

  final relay = RelayServer();
  var failed = false;
  try {
    step('2/4 启动中转 + DomSession，等待首份全量快照');
    await relay.start();
    final session = DomSession(page: page, relay: relay);
    await session.start();
    await session.firstFullSnapshot.timeout(
      const Duration(seconds: 20),
      onTimeout: () => throw TimeoutException('首份全量快照 20s 未到达'),
    );

    step('3/4 采样 $sampleSeconds 秒（统计 dom 通道导线字节）');
    final client = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relay.port}/ws'),
    );
    await client.ready;
    client.sink.add(
      RelayEnvelope(
        channel: RelayChannel.ctrl,
        type: RelayMessageType.auth,
        seq: 0,
        ts: 0,
        data: {'token': relay.token},
      ).encode(),
    );

    var domBytes = 0;
    var domMessages = 0;
    var fullBytes = 0; // 全量快照（压缩后）的导线成本
    var incBytes = 0;
    var incEvents = 0;
    final sub = client.stream.listen((raw) {
      final text = raw as String;
      RelayEnvelope env;
      try {
        env = RelayEnvelope.decode(text);
      } catch (_) {
        return;
      }
      if (env.channel != RelayChannel.dom) return;
      domMessages++;
      domBytes += text.length;
      if (env.type == RelayMessageType.full) {
        fullBytes += text.length;
      } else {
        incBytes += text.length;
        final data = env.data;
        if (data is Map && data['t'] == 'batch') {
          final events = data['events'];
          if (events is List) incEvents += events.length;
        }
      }
    });

    await Future<void>.delayed(const Duration(seconds: sampleSeconds));
    await sub.cancel();
    await client.sink.close();

    final status = session.status();
    stdout.writeln('dom 消息 $domMessages 条 / $domBytes B'
        '（全量 $fullBytes B，增量 $incBytes B / $incEvents 事件）');
    stdout.writeln(
      '会话：batches=${status.batchesReceived} '
      'envelopes=${status.envelopesSent} inputs=${status.inputsDispatched} '
      'lastError=${status.lastError}',
    );

    step('4/4 会话停止 + 页面零残留校验 + 写报告');
    await session.stop();
    final residue = await page.evaluate('''
JSON.stringify({
  installed: !!window.__gciCollectorInstalled,
  collector: typeof window.__gciCollector,
  emit: typeof window.__gciEmit,
  resync: typeof window.__gciResync,
})
''');
    stdout.writeln('残留检查：$residue');

    final kbps = (domBytes / sampleSeconds / 1024).toStringAsFixed(1);
    final report = StringBuffer()
      ..writeln('# 真机 DOM 重绘带宽实测（#18）')
      ..writeln()
      ..writeln('- 时间：${DateTime.now().toLocal()}')
      ..writeln('- 目标：ChatGPT.app 主 shell（attach 9238，只读）')
      ..writeln('- 采样：$sampleSeconds 秒，无 caps 客户端（文本帧，含压缩）')
      ..writeln()
      ..writeln('## 数据')
      ..writeln()
      ..writeln('| 指标 | 值 |')
      ..writeln('|------|-----|')
      ..writeln('| 全量快照导线成本（压缩后） | $fullBytes B |')
      ..writeln('| 增量总量（$sampleSeconds s） | $incBytes B / $incEvents 事件 |')
      ..writeln('| dom 消息总数 | $domMessages |')
      ..writeln('| 平均带宽 | $kbps KB/s |')
      ..writeln('| 会话输入下发 | ${status.inputsDispatched}（应为 0，只读） |')
      ..writeln('| lastError | ${status.lastError} |')
      ..writeln()
      ..writeln('## 残留检查')
      ..writeln()
      ..writeln('```json')
      ..writeln(residue)
      ..writeln('```')
      ..writeln()
      ..writeln('对照（#4 未压缩原始值）：全量快照 2,859,782 B；'
          '3 秒 24 事件 2,876,630 B。');
    final ts = DateTime.now()
        .toLocal()
        .toString()
        .replaceAll(RegExp(r'[^0-9]'), '')
        .substring(0, 14);
    final reportPath = 'docs/research/dom-bandwidth-$ts.md';
    await File(reportPath).writeAsString(report.toString());
    stdout.writeln('报告：$reportPath');
    await connection.client.close();
  } catch (e) {
    stderr.writeln('实测失败：$e');
    failed = true;
  } finally {
    await relay.stop();
  }
  if (failed) exitCode = 1;
}
