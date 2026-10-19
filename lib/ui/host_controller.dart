/// 宿主编排层（工单 #13）：四模块 UI 与底层服务之间的单一状态入口。
///
/// 聚合：MacLauncher 连接（lib/sdk/）、目标应用检测与带参启动
///（lib/launcher/）、检查器探针（lib/inspector/）、中转（lib/relay/）、
/// 远程接管会话（lib/dom/ 与 lib/video/，一期互斥）。
///
/// 测试约定：传 `autoRefresh: false` 关闭周期刷新定时器（widget 测试
/// 不允许悬挂 Timer）；会话/CDP 用 [cdpConnector] 注入替身。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maclauncher_sdk/maclauncher_sdk.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cdp/cdp.dart';
import '../dom/dom.dart';
import '../inspector/inspector.dart';
import '../launcher/launcher.dart';
import '../relay/relay.dart';
import '../video/video.dart';
import '../sdk/launcher_connection.dart';

/// 远程接管会话种类（一期互斥：同一时刻至多一个会话占用中转回调）。
enum SessionKind {
  none('无会话'),
  dom('DOM 重绘'),
  video('视频流');

  const SessionKind(this.label);

  final String label;
}

/// CDP 连接工厂（可注入替身；默认走 connectCdp 回退链）。
typedef CdpConnector = Future<CdpConnection> Function({required int debugPort});

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
    // 注意：构造器体内 profile 是初始化形参（可空），需 this. 走字段。
    _debugPort = this.profile.defaultDebugPort;
    _sdkStateSub = this.launcher.states.listen((status) {
      sdkStatus = status;
      notifyListeners();
    });
    if (autoRefresh) {
      // 周期刷新中转/会话快照（它们是无流的轮询型状态）。
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        // 注意：构造器体内 launcher 是初始化形参（可空），需 this. 走字段。
        if (this.launcher.relay.isRunning || sessionKind != SessionKind.none) {
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

  /// 生效调试端口：profile 默认值，loadSettings() 可覆盖，UI 可改。
  static const String _kDebugPortKey = 'gci.debugPort';
  static const String _kRelayPortKey = 'gci.relayPort';

  /// 当前使用的 CDP 调试端口（可在启动器页修改并持久化，#26）。
  int get debugPort => _debugPort;
  late int _debugPort;

  /// 修改调试端口（1024-65535），持久化到本机设置。
  Future<void> setDebugPort(int port) async {
    if (port < 1024 || port > 65535) {
      throw ArgumentError('端口须在 1024-65535 之间：$port');
    }
    _debugPort = port;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDebugPortKey, port);
  }

  /// 中转台远程访问端口：0 = 随机（默认），否则固定（多实例并存时
  /// 各配不同端口，#26）。
  int get relayPort => _relayPort;
  int _relayPort = 0;

  /// 修改中转端口（0 或 1024-65535），持久化到本机设置。
  /// 中转运行中修改会在下次启动中转时生效。
  Future<void> setRelayPort(int port) async {
    if (port != 0 && (port < 1024 || port > 65535)) {
      throw ArgumentError('端口须是 0（随机）或 1024-65535：$port');
    }
    _relayPort = port;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kRelayPortKey, port);
  }

  /// 启动时加载持久化设置（端口等）。
  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final port = prefs.getInt(_kDebugPortKey);
    if (port != null && port >= 1024 && port <= 65535) {
      _debugPort = port;
    }
    final relayPort = prefs.getInt(_kRelayPortKey);
    if (relayPort != null &&
        (relayPort == 0 || (relayPort >= 1024 && relayPort <= 65535))) {
      _relayPort = relayPort;
    }
    final kbps = prefs.getInt(_kVideoBitrateKbpsKey);
    if (kbps != null && kbps >= 1000 && kbps <= 50000) {
      videoBitrateKbps = kbps;
    }
    notifyListeners();
  }

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
        await appLauncher.launch(
          profile,
          debugPort: _debugPort,
          confirmRealTarget: confirmed,
        );
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
    await launcher.startRelay(allowLanAccess: allowLanAccess, port: _relayPort);
    // 顺带探测编码能力（#25），驱动中转台矩阵与视频设置可用性
    await refreshVideoCapabilities();
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
      await launcher.startRelay(
        allowLanAccess: allowLanAccess,
        port: _relayPort,
      );
    }
  });

  /* ---------- 远程接管会话（互斥） ---------- */

  SessionKind _sessionKind = SessionKind.none;
  CdpConnection? _cdpConnection;
  DomSession? _domSession;
  VideoSession? _videoSession;

  /// 视频流编码参数（#25/#27）：启动视频会话时生效。
  VideoCodecKind videoCodec = VideoCodecKind.h264;
  VideoEncoderKind videoEncoderKind = VideoEncoderKind.auto;

  static const String _kVideoBitrateKbpsKey = 'gci.videoBitrateKbps';

  /// 码率（kbps，1M–50M 滑条；#27）。
  int videoBitrateKbps = 2000;

  void setVideoCodec(VideoCodecKind v) {
    videoCodec = v;
    notifyListeners();
  }

  void setVideoEncoderKind(VideoEncoderKind v) {
    videoEncoderKind = v;
    notifyListeners();
  }

  Future<void> setVideoBitrateKbps(int kbps) async {
    if (kbps < 1000 || kbps > 50000) {
      throw ArgumentError('码率须在 1000-50000 kbps（1-50 Mbps）之间：$kbps');
    }
    videoBitrateKbps = kbps;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kVideoBitrateKbpsKey, kbps);
  }

  /// 滑条拖动中的预览更新（不持久化；松手时由 setVideoBitrateKbps 落盘）。
  void previewVideoBitrateKbps(int kbps) {
    videoBitrateKbps = kbps;
    notifyListeners();
  }

  /// 编码能力矩阵（#25）：refreshVideoCapabilities 后填充。
  List<EncoderCapability> encoderCapabilities = const [];

  /// 探测到的 ffmpeg 路径（未找到为 null）。
  String? ffmpegPath;

  /// ffmpeg 一键安装状态（#25 去沙盒后内置安装）。
  bool ffmpegInstalling = false;

  /// 下载百分比（0-100；无进度阶段为 null）。
  double? ffmpegInstallPercent;

  /// 最近一行安装输出（日志展示）。
  String ffmpegInstallLine = '';

  /// 内置安装 ffmpeg：经 Homebrew 执行 brew install ffmpeg，
  /// 解析输出驱动进度条；完成后自动重新探测编码能力。
  Future<void> installFfmpeg() => _run('安装 ffmpeg', () async {
    final brew = await const FfmpegInstaller().findBrew();
    if (!brew.available) {
      throw StateError('未找到 Homebrew：请先安装 brew（https://brew.sh）');
    }
    ffmpegInstalling = true;
    ffmpegInstallPercent = null;
    ffmpegInstallLine = '';
    notifyListeners();
    try {
      await for (final progress in const FfmpegInstaller().install(
        brew.path!,
      )) {
        ffmpegInstallPercent = progress.percent;
        ffmpegInstallLine = progress.line;
        notifyListeners();
      }
    } finally {
      ffmpegInstalling = false;
    }
    await refreshVideoCapabilities();
  });

  /// 探测 ffmpeg 与各编码器可用性（编译级；硬编实际可用性以会话
  /// 启动时的 2s 探测回退为准）。
  Future<void> refreshVideoCapabilities() async {
    final lookup = await const FfmpegLocator().find();
    ffmpegPath = lookup.path;
    encoderCapabilities = lookup.available
        ? await probeEncoderCapabilities(lookup.path!)
        : const <EncoderCapability>[];
    notifyListeners();
  }

  /// 最近一次会话枚举到的 shell 页面清单（#16 tab 切换数据源）。
  List<CdpTargetInfo> _shellTargets = const [];

  /// 当前会话接管的 shell 目标 id。
  String? _activeTargetId;

  SessionKind get sessionKind => _sessionKind;

  /// shell 页面清单（无会话时为空；#16）。
  List<CdpTargetInfo> get shellTargets => _shellTargets;

  /// 当前接管的 shell 目标 id（无会话时为 null）。
  String? get activeShellTargetId => _activeTargetId;

  /// 当前会话状态快照（无会话时为 null）。
  Object? get sessionStatus => switch (_sessionKind) {
    SessionKind.dom => _domSession?.status(),
    SessionKind.video => _videoSession?.status,
    SessionKind.none => null,
  };

  /// 当前会话使用的 CDP 实现名（诊断展示）。
  String? get cdpImplementationName => _cdpConnection?.implementationName;

  /// 启动接管会话：attach shell 页面后按种类创建 Dom/Screencast 会话。
  ///
  /// 中转必须先运行（会话要往 dom/frame 通道广播）。[targetId] 指定
  /// 接管的 shell 页面（#16 tab 切换）；缺省取主窗口。
  Future<void> startSession(SessionKind kind, {String? targetId}) =>
      _run('启动${kind.label}会话', () async {
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
          final shells = targets
              .where((t) => isShellTarget(t, profile.shellUrlSchemes))
              .toList(growable: false);
          final CdpTargetInfo shell;
          if (targetId != null) {
            shell = shells.firstWhere(
              (t) => t.id == targetId,
              orElse: () => throw StateError('目标 $targetId 不是 shell 页面（或已消失）'),
            );
          } else {
            shell = findShellTarget(targets, profile.shellUrlSchemes);
          }
          final page = await connection.client.attachTo(shell);
          void handleSwitch(String id) => unawaited(switchTarget(id));
          switch (kind) {
            case SessionKind.dom:
              final session = DomSession(
                page: page,
                relay: relay,
                onSwitchRequested: handleSwitch,
              );
              await session.start();
              _domSession = session;
            case SessionKind.video:
              final session = VideoSession(
                page: page,
                relay: relay,
                codec: videoCodec,
                encoderKind: videoEncoderKind,
                bitrateKbps: videoBitrateKbps,
                onSwitchRequested: handleSwitch,
              );
              await session.start();
              _videoSession = session;
            case SessionKind.none:
              break;
          }
          _cdpConnection = connection;
          _sessionKind = kind;
          _shellTargets = shells;
          _activeTargetId = shell.id;
          _broadcastShells(relay);
        } on Object {
          await connection.client.close();
          rethrow;
        }
      });

  /// 切换接管的 shell 页面（#16）：停当前会话、attach 新目标、
  /// 以相同模式重建会话。无会话或目标即当前目标时为 no-op；
  /// 目标不在已枚举的 shell 清单中时报错且**不动当前会话**（先校验
  /// 再切换，避免非法目标把会话打掉）。
  Future<void> switchTarget(String targetId) async {
    final kind = _sessionKind;
    if (kind == SessionKind.none || busy) return;
    if (targetId == _activeTargetId) return;
    if (!_shellTargets.any((t) => t.id == targetId)) {
      lastError = '目标 $targetId 不是 shell 页面（或已消失）';
      notifyListeners();
      return;
    }
    await stopSession();
    await startSession(kind, targetId: targetId);
  }

  /// 向远程端广播 shell 清单（tab 栏数据源）。
  void _broadcastShells(RelayServer relay) {
    relay.broadcast(RelayChannel.ctrl, RelayMessageType.shells, {
      'targets': [
        for (final t in _shellTargets)
          {
            'id': t.id,
            'title': t.title,
            'url': t.url,
            'primary': isPrimaryShellTarget(t, profile.shellUrlSchemes),
          },
      ],
      'activeId': _activeTargetId,
    });
  }

  /// 停止接管会话并断开 CDP（不杀目标应用进程）。幂等。
  Future<void> stopSession() async {
    await _domSession?.stop();
    await _videoSession?.stop();
    _domSession = null;
    _videoSession = null;
    _sessionKind = SessionKind.none;
    await _cdpConnection?.client.close();
    _cdpConnection = null;
    _shellTargets = const [];
    _activeTargetId = null;
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
