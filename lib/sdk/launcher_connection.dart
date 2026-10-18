import 'dart:async';

import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import '../relay/relay.dart';

/// MacLauncher 连接生命周期（工单 #7）。
///
/// 持有 SDK 连接与 relay 服务的回调；中转后端真实实现见 lib/relay/（#8）。
/// 契约要点（SDK_INTEGRATION.md）：
/// - `onStatus` 如实回报快照，`observedAt` 用 UTC 当前时间；15 秒未更新
///   会被启动器标 stale。
/// - `onRecycle` 回收业务资源（端口/连接），不退出应用进程本身。
/// - `pending-approval` 拒绝是批准前的正常状态，SDK 自动重试，不提示用户。
class LauncherConnection {
  LauncherConnection();

  static const String projectId = 'com.ghost233.ghostcodexinspect';
  static const String projectName = 'Ghost Codex Inspect';
  static const String relayServiceId = 'relay';

  MacLauncherSdk? _sdk;
  StreamSubscription<SdkConnectionStatus>? _stateSub;
  final _stateController = StreamController<SdkConnectionStatus>.broadcast();

  /// 中转后端（#8）：onStatus 如实回报、onRecycle 停服务回收端口。
  final RelayServer _relay = RelayServer();

  /// 中转服务实例（宿主 UI 读取 token/accessUrl 展示给用户）。
  RelayServer get relay => _relay;

  /// 启动中转（宿主 UI 入口）。默认绑 127.0.0.1；[allowLanAccess] 为
  /// 「允许局域网访问」开关，打开时绑 LAN 网卡 IPv4，绝不绑 0.0.0.0。
  Future<void> startRelay({bool allowLanAccess = false}) =>
      _relay.start(allowLanAccess: allowLanAccess);

  /// 停止中转（宿主 UI 入口）：回收端口、踢掉远程端，不退出进程。
  Future<void> stopRelay() => _relay.stop();

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

  /// relay 服务状态：如实回报中转快照；端口/绑定地址/远程端数量放入
  /// message（ServiceStatus 无结构化字段承载），observedAt 用 UTC。
  Future<ServiceStatus> _relayStatus() async {
    final s = _relay.status();
    if (!s.running) {
      return ServiceStatus(
        state: ServiceState.stopped,
        observedAt: s.observedAt,
        message: '中转未运行',
      );
    }
    return ServiceStatus(
      state: ServiceState.running,
      observedAt: s.observedAt,
      ready: true,
      message: '中转运行中：${s.address}:${s.port}，已连接远程端 ${s.clientCount} 个',
    );
  }

  /// 回收 relay 业务资源：停中转、回收端口、踢掉远程端；不退出应用进程。
  Future<void> _recycleRelay() async {
    await _relay.stop();
  }

  /// 只关闭 SDK 通信；从不触发业务回收（SDK 固定语义）。幂等。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stateSub?.cancel();
    await _sdk?.dispose();
    await _stateController.close();
  }
}
