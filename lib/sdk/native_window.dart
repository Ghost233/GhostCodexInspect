import 'package:flutter/services.dart';

/// 原生窗口桥（macos/Runner/MainFlutterWindow.swift 的对端）：
/// - setEntryManaged：MacLauncher 托管时隐藏自有菜单栏入口；
/// - activateMainWindow：启动器「打开窗口」请求时激活主窗口；
/// - installQuitHandler：原生退出前回调 Dart 收尾（停会话/中转）。
///
/// 测试环境无原生实现：invoke 静默降级（false / 无操作）。
class NativeWindowBridge {
  NativeWindowBridge._();

  static const MethodChannel _channel = MethodChannel(
    'com.ghost233.ghostcodexinspect/native',
  );

  /// 设置 MacLauncher 托管状态；返回是否生效。无原生端时返回 false。
  static Future<bool> setEntryManaged(bool managed) async {
    try {
      return await _channel.invokeMethod<bool>('setEntryManaged', managed) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 激活主窗口（从菜单栏/Dock/启动器唤起）。无原生端时无操作。
  static Future<void> activateMainWindow() async {
    try {
      await _channel.invokeMethod<void>('activateMainWindow');
    } on MissingPluginException {
      // 测试/非 macOS 环境无原生端
    }
  }

  /// 安装退出前收尾回调：返回 true 才放行退出。
  static void installQuitHandler(Future<bool> Function() prepareToQuit) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      return prepareToQuit();
    });
  }
}
