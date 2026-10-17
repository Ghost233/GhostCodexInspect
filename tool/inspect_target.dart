// 只读勘察目标应用：检测 + 前提校验，绝不启动或停止目标进程。
//
// 用于验证内置适配（TargetProfile.chatGpt）对真实目标应用的重命名框架、
// NSPrincipalClass、asar 载荷与签名状态的识别。仅读取文件系统与执行
// `codesign -dv`（只读），不触碰目标应用进程。
//
// 运行（仓库根目录）：
//   /Users/ghost233/flutter/bin/dart run tool/inspect_target.dart
import 'dart:io';

import 'package:ghost_codex_inspect/inspector/inspector.dart';
import 'package:ghost_codex_inspect/launcher/launcher.dart';

Future<void> main() async {
  final inspector = Inspector();
  final report = await inspector.checkPreflight(TargetProfile.chatGpt);
  stdout.writeln(report.toPrettyJson());
  if (!report.passed) exitCode = 1;
}
