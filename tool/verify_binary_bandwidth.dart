// 二期二进制帧验收（工单 #15）：fixture 画面流下同时挂一个 v2（bin.v2）
// 客户端与一个 v1（纯文本）客户端，跑同一动画窗口，对比两侧实际收到的
// 字节数——v2 必须明显更省且画面帧可用（JPEG 头校验），v1 客户端仍能
// 正常收文本信封（向后兼容）。
//
// 用法：dart run tool/verify_binary_bandwidth.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ghost_codex_inspect/cdp/cdp.dart';
import 'package:ghost_codex_inspect/launcher/app_launcher.dart';
import 'package:ghost_codex_inspect/launcher/target_profile.dart';
import 'package:ghost_codex_inspect/relay/relay.dart';
import 'package:ghost_codex_inspect/screencast/screencast.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const int debugPort = 9240; // fixture 与真机（9238）隔离（#14 事故修复）

void main() async {
  // 端口占用预检：fixture 调试端口被占（多半是上次残留）时拒绝启动。
  if (await AppLauncher().isDebugPortAlive(debugPort)) {
    stderr.writeln('端口 $debugPort 已被占用（可能残留 fixture），拒绝启动。');
    exitCode = 2;
    return;
  }

  final profile = TargetProfile.electronFixture(
    electronAppPath: 'tool/fixture/node_modules/electron/dist/Electron.app',
    fixtureDir: 'tool/fixture',
  );
  final launcher = AppLauncher();
  final relay = RelayServer();

  stdout.writeln('1/5 启动 fixture（调试端口 $debugPort）…');
  await launcher.launch(profile, debugPort: debugPort);
  try {
    stdout.writeln('2/5 连 CDP 并开画面流…');
    final connection = await connectCdp(debugPort: debugPort);
    final shell = findShellTarget(
        await connection.client.listTargets(), profile.shellUrlSchemes);
    final page = await connection.client.attachTo(shell);
    await relay.start();
    // 限帧会压低样本量，验收用 everyNthFrame: 1 全速推帧。
    final session = ScreencastSession(page: page, relay: relay,
        everyNthFrame: 1);
    await session.start();
    await session.firstFrame.timeout(const Duration(seconds: 10));

    stdout.writeln('3/5 挂 v2 与 v1 客户端，跑动画窗口…');
    final (v2, v2Stream) = await _connect(relay, caps: [kBinaryCapability]);
    final (_, v1Stream) = await _connect(relay);
    final v2Bytes = _ByteCounter(v2Stream);
    final v1Bytes = _ByteCounter(v1Stream);
    final v2Sink = v2.sink;

    // 动画源：每秒反色 10 次，持续 4s（画面稳定变化才产帧）。
    await page.evaluate(
        "setInterval(() => { document.body.style.filter = "
        "document.body.style.filter === 'invert(1)' ? '' : 'invert(1)'; },"
        ' 100)');
    await Future<void>.delayed(const Duration(seconds: 4));
    await page.evaluate('void 0');

    stdout.writeln('4/5 统计…');
    final v2Stat = await v2Bytes.stop();
    final v1Stat = await v1Bytes.stop();
    final ratio = v1Stat.bytes == 0
        ? 0.0
        : v2Stat.bytes / v1Stat.bytes;
    stdout.writeln('v1（文本帧）: ${v1Stat.bytes}B / ${v1Stat.frames} 帧');
    stdout.writeln('v2（二进制）: ${v2Stat.bytes}B / ${v2Stat.frames} 帧');
    stdout.writeln('带宽比 v2/v1 = ${ratio.toStringAsFixed(3)}');

    stdout.writeln('5/5 断言…');
    _expect(v2Stat.frames >= 10, 'v2 客户端应收到足够帧（${v2Stat.frames}）');
    _expect(v1Stat.frames >= 10, 'v1 客户端应收到足够帧（${v1Stat.frames}）');
    _expect(ratio > 0 && ratio < 0.85,
        '二进制帧应明显省带宽（实测 $ratio，期望 < 0.85）');
    _expect(v2Stat.jpegFrames == v2Stat.frames,
        'v2 收到的每帧都应是 JPEG 原始字节');

    await v2Sink.close();
    await session.stop();
    await connection.client.close();
    stdout.writeln('全部通过 ✅');
  } finally {
    await relay.stop();
    await launcher.stop(profile);
  }
}

/// WS 流是单订阅的：authOk 等待与后续计数共用 asBroadcastStream。
Future<(WebSocketChannel, Stream<dynamic>)> _connect(RelayServer relay,
    {List<String>? caps}) async {
  final channel =
      WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}/ws'));
  await channel.ready;
  final stream = channel.stream.asBroadcastStream();
  channel.sink.add(RelayEnvelope(
    channel: RelayChannel.ctrl,
    type: RelayMessageType.auth,
    seq: 0,
    ts: 0,
    data: {'token': relay.token, 'caps': ?caps},
  ).encode());
  await stream
      .firstWhere((e) => e is String && e.contains('"authOk"'))
      .timeout(const Duration(seconds: 5));
  return (channel, stream);
}

/// 单侧字节/帧计数：文本帧按帧信封统计，二进制帧校验 JPEG 头。
class _ByteCounter {
  _ByteCounter(Stream<dynamic> stream) {
    _sub = stream.listen((event) {
      if (event is String) {
        bytes += utf8.encode(event).length;
        try {
          final env = RelayEnvelope.decode(event);
          if (env.type == RelayMessageType.frame) frames++;
        } on Object {
          // 非信封文本帧忽略
        }
      } else if (event is Uint8List) {
        bytes += event.length;
        frames++;
        if (event.length >= 2 &&
            event[kBinaryHeaderLength] == 0xFF &&
            event[kBinaryHeaderLength + 1] == 0xD8) {
          jpegFrames++;
        }
      }
    });
  }

  late final StreamSubscription<dynamic> _sub;
  int bytes = 0;
  int frames = 0;
  int jpegFrames = 0;

  Future<_ByteCounter> stop() async {
    await _sub.cancel();
    return this;
  }
}

void _expect(bool ok, String message) {
  if (!ok) {
    stderr.writeln('断言失败：$message');
    exitCode = 1;
    throw StateError(message);
  }
}
