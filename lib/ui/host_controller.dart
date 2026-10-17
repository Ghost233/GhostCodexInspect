/// 宿主编排层（工单 #13）：四模块 UI 与底层服务之间的单一状态入口。
///
/// 聚合：MacLauncher 连接（lib/sdk/）、目标应用检测与带参启动
///（lib/launcher/）、检查器探针（lib/inspector/）、中转（lib/relay/）、
/// 远程接管会话（lib/dom/ 与 lib/screencast/，一期互斥）。
///
/// 测试约定：传 `autoRefresh: false` 关闭周期刷新定时器（widget 测试
/// 不允许悬挂 Timer）；会话/CDP 用 [cdpConnector] 注入替身。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';

import '../cdp/cdp.dart';
import '../dom/dom.dart';
import '../inspector/inspector.dart';
import '../launcher/launcher.dart';
import '../relay/relay.dart';
import '../screencast/screencast.dart';
import '../sdk/launcher_connection.dart';

/// 远程接管会话种类（一期互斥：同一时刻至多一个会话占用中转回调）。
enum SessionKind {
  none('无会话'),
  dom('DOM 重绘'),
  screencast('画面流');

  const SessionKind(this.label);

  final String label;
}

/// CDP 连接工厂（可注入替身；默认走 connectCdp 回退链）。
typedef CdpConnector =
    Future<CdpConnection> Function({required int debugPort});

class HostController extends ChangeNotifier {
  HostController({
    LauncherConnection? launcher,
    AppLauncher? appLauncher,
    Inspector? inspector,
    TargetProfile? profile,
    CdpConnector? cdpConnector,
    this.autoRefresh = true,
  }) : launcher = launcher ?? LauncherConnection(),
       appLauncher = appLauncher ?? AppLauncher(),
       inspector = inspector ?? Inspector(),
       profile = profile ?? TargetProfile.chatGpt,
       _cdpConnector = cdpConnector ?? connectCdp {
    _sdkStateSub = this.launcher.states.listen((status) {
      sdkStatus = status;
      notifyListeners();
    });
    if (autoRefresh) {
      // 周期刷新中转/会话快照（它们是无流的轮询型状态）。
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        // 注意：构造器体内 launcher 是初始化形参（可空），需 this. 走字段。
        if (this.launcher.relay.isRunning ||
            sessionKind != SessionKind.none) {
          notifyListeners();
        }
      });
    }
  }

  /// MacLauncher 连接生命周期（#7）。
  final LauncherConnection launcher;

  /// 带参启动器（#10）。
  final AppLauncher appLauncher;

  /// 检查器（#10 薄壳）。
  final Inspector inspector;

  /// 一期目标应用（ChatGPT.app 内置适配）。
  final TargetProfile profile;

  /// 是否启用周期刷新定时器（测试传 false）。
  final bool autoRefresh;

  final CdpConnector _cdpConnector;
  StreamSubscription<SdkConnectionStatus>? _sdkStateSub;
  Timer? _ticker;

  /* ---------- MacLauncher 连接状态 ---------- */

  /// 最近一次 SDK 连接状态（未连接时为 null）。
  SdkConnectionStatus? sdkStatus;

  /// 连接 MacLauncher（幂等；autoConnect 由应用层决定是否调用）。
  void connectSdk() => launcher.connect();

  /* ---------- 启动器（目标应用） ---------- */

  /// 最近一次前提校验报告。
  PreflightReport? preflight;

  /// 正在运行中的目标应用实例 pid。
  List<int> runningPids = const [];

  /// 是否有操作在执行（按钮防重）。
  String? busyAction;

  /// 最近一次错误（就地展示）。
  String? lastError;

  bool get busy => busyAction != null;

  /// 目标是否在运行（按进程发现）。
  bool get targetRunning => runningPids.isNotEmpty;

  /// 生效调试端口（profile 默认值；一期不可在 UI 改）。
  int get debugPort => profile.defaultDebugPort;

  Future<void> _run(String action, Future<void> Function() body) async {
    if (busy) return;
    busyAction = action;
    lastError = null;
    notifyListeners();
    try {
      await body();
    } on Object catch (e) {
      lastError = e.toString();
    } finally {
      busyAction = null;
      notifyListeners();
    }
  }

  /// 重新检测目标应用（前提校验 + 进程发现）。
  Future<void> refreshTarget() => _run('检测目标应用', () async {
    preflight = await inspector.checkPreflight(profile);
    runningPids = await appLauncher.findRunningPids(profile);
  });

  /// 只刷新进程运行状态。
  Future<void> refreshRunningState() async {
    runningPids = await appLauncher.findRunningPids(profile);
    notifyListeners();
  }

  /// 带参启动目标应用。[confirmed] 必须来自 UI 确认对话框。
  Future<void> launchTarget({required bool confirmed}) =>
      _run('带参启动', () async {
        await appLauncher.launch(profile, confirmRealTarget: confirmed);
        await refreshRunningState();
      });

  /// 停止目标应用（先 SIGTERM，超时 SIGKILL）。
  Future<void> stopTarget({required bool confirmed}) =>
      _run('停止目标应用', () async {
        // 有接管会话时先收尾，避免悬挂的 CDP 连接。
        if (sessionKind != SessionKind.none) await stopSession();
        await appLauncher.stop(profile, confirmRealTarget: confirmed);
        await refreshRunningState();
      });

  /// 重启 = 停止后带参启动（调试端口不变）。
  Future<void> restartTarget({required bool confirmed}) =>
      _run('重启目标应用', () async {
        if (sessionKind != SessionKind.none) await stopSession();
        await appLauncher.restart(profile, confirmRealTarget: confirmed);
        await refreshRunningState();
      });

  /* ---------- 检查器 ---------- */

  /// 最近一次检查报告（前提校验 + CDP 健康探针）。
  InspectorReport? probeReport;

  /// 执行完整检查（前提校验 + attach + shell 枚举 + 标题探针）。
  Future<void> runProbe() => _run('执行检查', () async {
    probeReport = await inspector.probe(profile);
  });

  /* ---------- 中转 ---------- */

  /// 「允许局域网访问」开关（下次启动中转时生效；运行中切换会重启中转）。
  bool allowLanAccess = false;

  RelayServerStatus get relayStatus => launcher.relay.status();

  List<RelayClientInfo> get relayClients => launcher.relay.clients;

  /// 带 token 的访问链接（未运行时为 null）。
  Uri? get accessUrl => launcher.relay.accessUrl;

  /// 本机只读预览链接（追加 `ro=1`，远程端不挂输入捕获层）。
  Uri? get previewUrl {
    final url = accessUrl;
    if (url == null) return null;
    return Uri.parse('${url.toString()}&ro=1');
  }

  /// 启动中转（默认绑 127.0.0.1）。
  Future<void> startRelay() => _run('启动中转', () async {
    await launcher.startRelay(allowLanAccess: allowLanAccess);
  });

  /// 停止中转（回收端口、踢掉远程端）。
  Future<void> stopRelay() => _run('停止中转', () async {
    if (sessionKind != SessionKind.none) await stopSession();
    await launcher.stopRelay();
  });

  /// 切换「允许局域网访问」；中转运行中会重启并换令牌。
  Future<void> setLanAccess(bool enabled) => _run('切换局域网访问', () async {
    allowLanAccess = enabled;
    if (launcher.relay.isRunning) {
      if (sessionKind != SessionKind.none) await stopSession();
      await launcher.stopRelay();
      await launcher.startRelay(allowLanAccess: allowLanAccess);
    }
  });

  /* ---------- 远程接管会话（互斥） ---------- */

  SessionKind _sessionKind = SessionKind.none;
  CdpConnection? _cdpConnection;
  DomSession? _domSession;
  ScreencastSession? _screencastSession;

  SessionKind get sessionKind => _sessionKind;

  /// 当前会话状态快照（无会话时为 null）。
  Object? get sessionStatus => switch (_sessionKind) {
    SessionKind.dom => _domSession?.status(),
    SessionKind.screencast => _screencastSession?.status(),
    SessionKind.none => null,
  };

  /// 当前会话使用的 CDP 实现名（诊断展示）。
  String? get cdpImplementationName => _cdpConnection?.implementationName;

  /// 启动接管会话：attach shell 页面后按种类创建 Dom/Screencast 会话。
  ///
  /// 中转必须先运行（会话要往 dom/frame 通道广播）。
  Future<void> startSession(SessionKind kind) => _run('启动${kind.label}会话', () async {
    if (kind == SessionKind.none) return;
    if (_sessionKind != SessionKind.none) {
      throw StateError('已有${_sessionKind.label}会话在运行，先停止再切换（一期互斥约定）');
    }
    final relay = launcher.relay;
    if (!relay.isRunning) {
      throw StateError('中转未运行：请先在「中转台」启动中转');
    }
    final connection = await _cdpConnector(debugPort: debugPort);
    try {
      final targets = await connection.client.listTargets();
      final shell = findShellTarget(targets, profile.shellUrlSchemes);
      final page = await connection.client.attachTo(shell);
      switch (kind) {
        case SessionKind.dom:
          final session = DomSession(page: page, relay: relay);
          await session.start();
          _domSession = session;
        case SessionKind.screencast:
          final session = ScreencastSession(page: page, relay: relay);
          await session.start();
          _screencastSession = session;
        case SessionKind.none:
          break;
      }
      _cdpConnection = connection;
      _sessionKind = kind;
    } on Object {
      await connection.client.close();
      rethrow;
    }
  });

  /// 停止接管会话并断开 CDP（不杀目标应用进程）。幂等。
  Future<void> stopSession() async {
    await _domSession?.stop();
    await _screencastSession?.stop();
    _domSession = null;
    _screencastSession = null;
    _sessionKind = SessionKind.none;
    await _cdpConnection?.client.close();
    _cdpConnection = null;
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    _ticker?.cancel();
    await _sdkStateSub?.cancel();
    await stopSession();
    await launcher.dispose();
    super.dispose();
  }
}
