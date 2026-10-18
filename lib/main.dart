import 'package:flutter/material.dart';

import 'ui/home_shell.dart';
import 'ui/host_controller.dart';
import 'ui/theme.dart';

void main() {
  runApp(const GhostCodexInspectApp());
}

class GhostCodexInspectApp extends StatefulWidget {
  const GhostCodexInspectApp({
    super.key,
    this.autoConnect = true,
    this.controller,
  });

  /// 是否启动即连接 MacLauncher SDK。测试传 false 避免 SDK 重连定时器
  /// 造成 widget 测试不变量校验失败（见 #7 工单踩坑）。
  final bool autoConnect;

  /// 测试可注入替身控制器；为空时自行创建默认实例。
  final HostController? controller;

  @override
  State<GhostCodexInspectApp> createState() => _GhostCodexInspectAppState();
}

class _GhostCodexInspectAppState extends State<GhostCodexInspectApp> {
  late final HostController _controller = widget.controller ?? HostController();

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) {
      _controller.connectSdk();
    }
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ghost Codex Inspect',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(Brightness.light),
      darkTheme: buildAppTheme(Brightness.dark),
      home: HomeShell(controller: _controller),
    );
  }
}
