import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

/// MacLauncher 连接生命周期（工单 #7）。
///
/// 只持有 SDK 连接与 relay 服务的回调骨架；中转后端的真实实现在 #8。
/// 契约要点（SDK_INTEGRATION.md）：
/// - `onStatus` 如实回报快照，`observedAt` 用 UTC 当前时间；15 秒未更新
///   会被启动器标 stale。
/// - `onRecycle` 回收业务资源（端口/连接），不退出应用进程本身。
/// - `pending-approval` 拒绝是批准前的正常状态，SDK 自动重试，不提示用户。
class LauncherConnection {
  LauncherConnection();

  static const String projectId = 'com.ghost233.ghostcodexinspect';
  static const String projectName = 'GhostCodexInspect';
  static const String relayServiceId = 'relay';

  MacLauncherSdk? _sdk;
  StreamSubscription<SdkConnectionStatus>? _stateSub;
  final _stateController = StreamController<SdkConnectionStatus>.broadcast();

  /// 待批准期间：pending-approval 重试噪音只公告一次。
  bool _pendingApproval = false;
  bool _disposed = false;

  /// 连接状态广播流（UI 订阅用）。
  Stream<SdkConnectionStatus> get states => _stateController.stream;

  SdkConnectionStatus? _lastStatus;
  SdkConnectionStatus? get lastStatus => _lastStatus;

  /// 连接启动器：立即返回，握手、心跳与重连由 SDK 在后台维持。幂等。
  void connect() {
    if (_disposed) throw StateError('连接已收尾');
    if (_sdk != null) return;
    final sdk = MacLauncherSdk.connect(
      projectId: projectId,
      projectName: projectName,
      // 运行时发现入口自报：打包运行时上报自身 .app，开发期退回当前可执行文件。
      entry: SdkEntry.currentAppBundle() ?? SdkEntry.currentExecutable(),
      services: {
        relayServiceId: ServiceCallbacks(
          name: '中转服务',
          onStatus: _relayStatus,
          onRecycle: _recycleRelay,
        ),
      },
    );
    _sdk = sdk;
    _stateSub = sdk.states.listen((status) {
      if (status.state == SdkConnectionState.rejected &&
          status.reason == kRejectReasonPendingApproval) {
        // 待批准不是错误：SDK 每 5 秒自动重试到用户批准。
        _pendingApproval = true;
      } else if (_pendingApproval &&
          status.state != SdkConnectionState.connecting &&
          status.state != SdkConnectionState.disconnected) {
        _pendingApproval = false;
      }
      _lastStatus = status;
      _stateController.add(status);
    });
  }

  /// relay 服务状态：中转后端尚未实现（#8），如实回报 stopped。
  Future<ServiceStatus> _relayStatus() async {
    return ServiceStatus(
      state: ServiceState.stopped,
      observedAt: DateTime.now().toUtc(),
      message: '中转后端尚未实现（工单 #8）',
    );
  }

  /// 回收 relay 业务资源（端口/连接），不退出应用进程。#8 接入真实回收。
  Future<void> _recycleRelay() async {}

  /// 只关闭 SDK 通信；从不触发业务回收（SDK 固定语义）。幂等。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateSub?.cancel();
    await _sdk?.dispose();
    await _stateController.close();
  }
}
