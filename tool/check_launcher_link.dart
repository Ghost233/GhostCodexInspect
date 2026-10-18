// MacLauncher（Ghost Launcher）实机联调检查：SDK 连接状态迁移 + 中转服务
// 状态上报链路。只观察与自控，不操作 MacLauncher 本身。
//
// 用法：dart run tool/check_launcher_link.dart
import 'dart:async';
import 'dart:io';

import 'package:ghost_codex_inspect/sdk/launcher_connection.dart';

Future<void> main() async {
  final conn = LauncherConnection();
  final sub = conn.states.listen((s) => stdout.writeln(
      '[state] ${s.state.name}${s.reason != null ? '（${s.reason}）' : ''}'));
  stdout.writeln('连接 MacLauncher…（未批准时会出现一次 pending-approval 提示）');
  conn.connect();

  // 等连接稳定（已连接或持续待批准）后再启中转，观察服务状态上报。
  await Future<void>.delayed(const Duration(seconds: 6));
  stdout.writeln('启动中转，验证 MacLauncher 服务状态上报…');
  await conn.startRelay();
  await Future<void>.delayed(const Duration(seconds: 4));
  stdout.writeln('中转状态：running=${conn.relay.isRunning} url=${conn.relay.accessUrl}');
  await conn.stopRelay();
  await Future<void>.delayed(const Duration(seconds: 2));
  stdout.writeln('中转已停。');
  await sub.cancel();
  await conn.dispose();
  stdout.writeln('收尾完成（dispose 不触发业务回收语义验证：中转已先于 dispose 停止）。');
}
