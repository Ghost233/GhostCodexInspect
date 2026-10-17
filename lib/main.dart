import 'package:flutter/material.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import 'sdk/launcher_connection.dart';

void main() {
  runApp(const GhostCodexInspectApp());
}

class GhostCodexInspectApp extends StatefulWidget {
  const GhostCodexInspectApp({super.key, this.autoConnect = true});

  /// 是否启动即连接 MacLauncher。测试关闭以避免 SDK 重连定时器悬挂。
  final bool autoConnect;

  @override
  State<GhostCodexInspectApp> createState() => _GhostCodexInspectAppState();
}

class _GhostCodexInspectAppState extends State<GhostCodexInspectApp> {
  final LauncherConnection _launcher = LauncherConnection();

  @override
  void initState() {
    super.initState();
    if (widget.autoConnect) _launcher.connect();
  }

  @override
  void dispose() {
    _launcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GhostCodexInspect',
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('GhostCodexInspect')),
        body: Center(
          child: StreamBuilder<SdkConnectionStatus>(
            stream: _launcher.states,
            initialData: _launcher.lastStatus,
            builder: (context, snapshot) {
              final status = snapshot.data;
              final text = status == null
                  ? '启动器连接：connecting'
                  : '启动器连接：${status.state.name}'
                      '${status.reason == null ? '' : '（${status.reason}）'}';
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('宿主脚手架（工单 #7）'),
                  const SizedBox(height: 8),
                  Text(text),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
