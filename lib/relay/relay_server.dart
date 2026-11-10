import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'bind_policy.dart';
import 'envelope.dart';
import 'relay_token.dart';

/// 鉴权失败的 WebSocket 关闭码（私有用途，4400 段为应用自定义）。
const int kRelayCloseUnauthorized = 4401;

/// 远程端连接信息（中转台 UI 列表用，工单 #13）。
class RelayClientInfo {
  const RelayClientInfo({required this.id, required this.authed});

  /// 连接序号（本次运行内自增）。
  final int id;

  /// 是否已通过 token 鉴权。
  final bool authed;

  @override
  String toString() => '远程端 #$id（${authed ? '已鉴权' : '待鉴权'}）';
}

/// 中转状态快照（onStatus 与宿主 UI 共用）。
class RelayServerStatus {
  RelayServerStatus({
    required this.running,
    required this.address,
    required this.port,
    required this.clientCount,
    required this.observedAt,
  });

  /// 中转是否在运行。
  final bool running;

  /// 绑定地址（如 127.0.0.1）；未运行时为 null。
  final String? address;

  /// 实际监听端口；未运行时为 null。
  final int? port;

  /// 当前已建立（含未通过鉴权）的远程端连接数。
  final int clientCount;

  /// 观测时刻（UTC）。
  final DateTime observedAt;
}

/// 宿主内中转（Relay）服务（工单 #8）。
///
/// 用 shelf + shelf_web_socket + shelf_static 实现内嵌 HTTP/WS server：
/// - HTTP：伺服远程端纯静态单页（[staticDir]，#9 并行开发中）；
/// - WS：单条 WebSocket 复用 dom/frame/input/ctrl 通道（信封协议见
///   envelope.dart），首消息令牌鉴权 + Origin/Host 校验防 DNS rebinding。
///
/// 绑定策略：默认 127.0.0.1；`start(allowLanAccess: true)` 监听 0.0.0.0。
class RelayServer {
  RelayServer({
    String? staticDir,
    this.wsPath = 'ws',
    this.authTimeout = const Duration(seconds: 5),
    this.onClientMessage,
  }) : staticDir = staticDir ?? resolveWebRoot();

  /// 远程端静态资产目录。默认 [resolveWebRoot]：打包/集成运行时使用
  /// app 包内 `flutter_assets/assets/web`，CLI 工具退回仓库相对路径。
  final String staticDir;

  /// 解析远程端静态资产根目录（真机走查发现：打包/集成测试场景下进程
  /// 工作目录不是仓库根，相对路径 `assets/web` 不存在）。
  ///
  /// 候选（首个存在的胜出）：
  /// 1. 环境变量 `GCI_WEB_ROOT`（工具/测试显式覆盖）；
  /// 2. 当前可执行文件所在 app 包内 flutter_assets（调试与发布两种布局）；
  /// 3. 相对路径 `assets/web`（CLI 工具从仓库根运行）。
  static String resolveWebRoot() {
    final env = Platform.environment['GCI_WEB_ROOT'];
    if (env != null && Directory(env).existsSync()) return env;
    // …/Ghost Codex Inspect.app/Contents/MacOS/Ghost Codex Inspect → Contents
    final exe = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
    final contents = File(exe).parent.parent.path;
    for (final layout in const [
      'Frameworks/App.framework/Resources/flutter_assets/assets/web',
      'Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/web',
    ]) {
      final candidate = '$contents/$layout';
      if (Directory(candidate).existsSync()) return candidate;
    }
    return 'assets/web';
  }

  /// WebSocket 端点路径（不含前导斜杠）。
  final String wsPath;

  /// 未鉴权连接的容忍时长，超时强制关闭。
  final Duration authTimeout;

  /// 已鉴权远程端消息回调（input/ctrl 等业务信封由上层消费）。
  void Function(int clientId, RelayEnvelope envelope)? onClientMessage;

  /// 远程端鉴权成功回调（工单 #11：新客户端接入/断线重连后由上层触发
  /// 全量快照重发，让晚到的远程端立即拿到完整画面）。
  void Function(int clientId)? onClientAuthed;

  /// 已鉴权远程端断开回调（#27：最后一个观众离开时上层暂停编码等
  /// 重负载管线）。
  void Function(int clientId)? onClientDisconnected;

  HttpServer? _server;
  InternetAddress? _bindAddress;
  InternetAddress? _accessAddress;
  String? _token;
  String? _accessKey;
  String _accessSession = RelayToken.generate();
  int _nextClientId = 1;
  final Map<int, _ClientSession> _clients = {};

  bool get isRunning => _server != null;

  /// 实际监听端口；未运行时为 null。
  int? get port => _server?.port;

  /// 绑定地址；未运行时为 null。
  InternetAddress? get bindAddress => _bindAddress;

  /// 本次运行的访问令牌（可由宿主传入固定值）。
  String? get token => _token;

  /// 当前远程端连接数。
  int get clientCount => _clients.length;

  /// 当前已鉴权远程端数（#27「无人观看不编码」的判定基准）。
  int get authedClientCount => _clients.values.where((c) => c.isAuthed).length;

  /// 当前远程端连接列表（中转台 UI 用）。
  List<RelayClientInfo> get clients => [
    for (final entry in _clients.entries)
      RelayClientInfo(id: entry.key, authed: entry.value.isAuthed),
  ];

  /// 带 token fragment 的访问 URL，供宿主 UI 展示/复制；
  /// fragment 不进 HTTP 请求与服务器日志。未运行时为 null。
  Uri? get accessUrl {
    final address = _accessAddress;
    final token = _token;
    final port = this.port;
    if (address == null || token == null || port == null) return null;
    return Uri.parse('http://${address.address}:$port/#t=$token');
  }

  /// 状态快照（如实回报；observedAt 为 UTC）。
  RelayServerStatus status() => RelayServerStatus(
    running: isRunning,
    address: _bindAddress?.address,
    port: port,
    clientCount: clientCount,
    observedAt: DateTime.now().toUtc(),
  );

  /// 启动中转。幂等：已运行时直接返回。
  ///
  /// [allowLanAccess] 打开时监听所有 IPv4 接口；默认绑 127.0.0.1。
  /// [port] 传 0 由系统分配空闲端口。
  /// [accessKey] 设置后，HTTP 页面和 WS Upgrade 均须先通过密钥登录。
  /// [fixedToken] 为空时每次启动生成随机 token。
  Future<void> start({
    bool allowLanAccess = false,
    int port = 0,
    String? accessKey,
    String? fixedToken,
  }) async {
    if (_server != null) return;
    if (accessKey != null && accessKey.isEmpty) {
      throw ArgumentError('访问密钥不能为空');
    }
    if (fixedToken != null && fixedToken.isEmpty) {
      throw ArgumentError('固定 token 不能为空');
    }
    final address = await resolveBindAddress(allowLanAccess: allowLanAccess);
    var accessAddress = InternetAddress.loopbackIPv4;
    if (allowLanAccess) {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      accessAddress =
          pickLanAddress(interfaces.expand((i) => i.addresses)) ??
          accessAddress;
    }
    final handler = _buildHandler(address);
    final server = await shelf_io.serve(handler, address, port);
    _server = server;
    _bindAddress = address;
    _accessAddress = accessAddress;
    _token = fixedToken ?? RelayToken.generate();
    _accessKey = accessKey;
    _accessSession = RelayToken.generate();
  }

  /// 手动轮转令牌：撤销登录状态，断开全部连接，旧 token 立即失效。
  Future<void> rotateToken({String? token}) async {
    if (token != null && token.isEmpty) throw ArgumentError('token 不能为空');
    _token = token ?? RelayToken.generate();
    await _revokeAccess();
  }

  Future<void> setAccessKey(String key) async {
    if (key.isEmpty) throw ArgumentError('访问密钥不能为空');
    _accessKey = key;
    await _revokeAccess();
  }

  Future<void> _revokeAccess() async {
    _accessSession = RelayToken.generate();
    for (final client in _clients.values.toList()) {
      await client.close(kRelayCloseUnauthorized, '凭据已更新，请重新登录');
    }
  }

  /// 停止中转：踢掉全部远程端、回收端口。不退出应用进程（对齐 MacLauncher
  /// SDK 的 onRecycle 语义）。幂等。
  Future<void> stop() async {
    final server = _server;
    if (server == null) return;
    _server = null;
    _token = null;
    _bindAddress = null;
    _accessAddress = null;
    _accessKey = null;
    _accessSession = RelayToken.generate();
    for (final client in _clients.values.toList()) {
      await client.close(1000, '中转停止');
    }
    _clients.clear();
    await server.close(force: true);
  }

  /// 向单个已鉴权远程端发信封（seq 由连接各自计数）。
  void sendTo(
    int clientId,
    RelayChannel channel,
    RelayMessageType type,
    Object? data,
  ) {
    _clients[clientId]?.send(channel, type, data);
  }

  /// 向全部已鉴权远程端广播信封（如 dom 增量、frame 帧）。
  ///
  /// [binaryPayload]（工单 #15 二期）：提供时，声明了 bin.v2 能力的
  /// 客户端收 v2 二进制帧（payload 原始字节，无 JSON/base64）；未声明的
  /// 旧客户端仍收 JSON 文本帧（[data] 须保持向后兼容形态）。
  void broadcast(
    RelayChannel channel,
    RelayMessageType type,
    Object? data, {
    Uint8List? binaryPayload,
  }) {
    for (final client in _clients.values) {
      if (!client._authed) continue;
      if (binaryPayload != null && client.supportsBinary) {
        client.sendBinary(channel, type, binaryPayload);
      } else {
        client.send(channel, type, data);
      }
    }
  }

  void _removeClient(int id) {
    final session = _clients.remove(id);
    if (session != null && session.isAuthed) {
      onClientDisconnected?.call(id);
    }
  }

  void _dispatch(int clientId, RelayEnvelope envelope) =>
      onClientMessage?.call(clientId, envelope);

  void _notifyAuthed(int clientId) => onClientAuthed?.call(clientId);

  Handler _buildHandler(InternetAddress address) {
    final allowedHosts = address == InternetAddress.anyIPv4
        ? null
        : <String>{address.address};
    // 绑回环时浏览器常以 localhost 访问，二者等价放行。
    if (address.isLoopback) allowedHosts!.add('localhost');
    final staticHandler = createStaticHandler(
      staticDir,
      defaultDocument: 'index.html',
    );
    final wsHandler = webSocketHandler(_onWebSocketConnect);
    return (Request request) async {
      if (request.url.path == 'auth') return _login(request, allowedHosts);
      if (_accessKey != null && !_hasAccess(request)) {
        if (request.url.path.isEmpty ||
            request.url.path == 'index.html' ||
            request.url.path == 'login.html') {
          return Response.ok(
            await File('$staticDir/login.html').readAsString(),
            headers: {
              'content-type': 'text/html; charset=utf-8',
              'cache-control': 'no-store',
              'content-security-policy': "frame-ancestors 'none'",
            },
          );
        }
        return Response.unauthorized(
          '请先输入访问密钥',
          headers: {'cache-control': 'no-store'},
        );
      }
      if (request.url.path == wsPath) {
        // 纵深防御：防 DNS rebinding 借浏览器跨站页面打回环服务。
        final rejectReason = checkWebSocketHeaders(
          hostHeader: request.headers['host'],
          originHeader: request.headers['origin'],
          allowedHosts: allowedHosts,
        );
        if (rejectReason != null) {
          return Response.forbidden(
            jsonEncode({'error': rejectReason}),
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        return wsHandler(request);
      }
      // 静态伺服只服务 assets/web 内已知路径，shelf_static 已防目录遍历。
      // 页面和资源不缓存，凭据更新后重新加载必须再次登录。
      final response = await staticHandler(request);
      return response.change(headers: {'cache-control': 'no-store'});
    };
  }

  bool _hasAccess(Request request) {
    final cookies = request.headers['cookie'] ?? '';
    return cookies.split(';').any((part) {
      final pair = part.trim().split('=');
      return pair.length == 2 &&
          pair[0] == 'gci_access_$port' &&
          RelayToken.equals(pair[1], _accessSession);
    });
  }

  Future<Response> _login(Request request, Set<String>? allowedHosts) async {
    const headers = {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
    };
    if (request.method == 'GET') {
      return Response(
        _accessKey == null || _hasAccess(request)
            ? HttpStatus.ok
            : HttpStatus.unauthorized,
        body: '{}',
        headers: headers,
      );
    }
    if (request.method != 'POST' ||
        request.headers['content-type']?.split(';').first.trim() !=
            'application/json') {
      return Response(HttpStatus.badRequest, headers: headers);
    }
    if (checkWebSocketHeaders(
          hostHeader: request.headers['host'],
          originHeader: request.headers['origin'],
          allowedHosts: allowedHosts,
        ) !=
        null) {
      return Response.forbidden('{}', headers: headers);
    }
    final body = <int>[];
    await for (final chunk in request.read()) {
      body.addAll(chunk);
      if (body.length > 4096) {
        return Response(HttpStatus.requestEntityTooLarge, headers: headers);
      }
    }
    Object? data;
    try {
      data = jsonDecode(utf8.decode(body));
    } on FormatException {
      return Response(HttpStatus.badRequest, headers: headers);
    }
    final key = data is Map ? data['key'] : null;
    if (_accessKey == null ||
        key is! String ||
        !RelayToken.equals(key, _accessKey!)) {
      return Response.unauthorized('{}', headers: headers);
    }
    final cookie = Cookie('gci_access_$port', _accessSession)
      ..httpOnly = true
      ..sameSite = SameSite.strict
      ..secure = request.requestedUri.scheme == 'https'
      ..path = '/';
    return Response.ok(
      '{}',
      headers: {...headers, 'set-cookie': cookie.toString()},
    );
  }

  void _onWebSocketConnect(WebSocketChannel channel, String? protocol) {
    final id = _nextClientId++;
    final session = _ClientSession(id, channel, this);
    _clients[id] = session;
    session.start();
  }
}

/// 防 DNS rebinding 的 WS Upgrade 头校验（纯函数，可测）。
///
/// 返回 null 表示放行；否则返回拒绝原因。
/// - Host 须合法，且在 [allowedHosts] 内；全接口监听时清单为 null。
/// - 浏览器 Origin 必须与 Host 同源（含端口）；非浏览器可不带 Origin。
String? checkWebSocketHeaders({
  required String? hostHeader,
  required String? originHeader,
  required Set<String>? allowedHosts,
}) {
  final host = hostHeader?.trim();
  if (host == null || host.isEmpty) {
    return '缺少 Host 头';
  }
  final hostUri = Uri.tryParse('http://$host');
  if (hostUri == null ||
      hostUri.host.isEmpty ||
      hostUri.userInfo.isNotEmpty ||
      hostUri.path.isNotEmpty ||
      hostUri.hasQuery ||
      hostUri.hasFragment) {
    return 'Host 头无效';
  }
  if (allowedHosts != null && !allowedHosts.contains(hostUri.host)) {
    return 'Host 头不在允许清单：$host';
  }
  final origin = originHeader?.trim();
  if (origin != null && origin.isNotEmpty) {
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host != hostUri.host ||
        uri.authority != host) {
      return 'Origin 头不在允许清单：$origin';
    }
  }
  return null;
}

/// 单个远程端连接会话：鉴权状态机 + 每连接出站 seq 计数。
class _ClientSession {
  _ClientSession(this.id, this.channel, this._server);

  final int id;
  final WebSocketChannel channel;
  final RelayServer _server;

  bool _authed = false;

  /// 客户端在 auth 握手里声明的能力（如 bin.v2）。
  final Set<String> _caps = {};

  /// 是否支持 v2 二进制帧下行（#15）。
  bool get supportsBinary => _caps.contains(kBinaryCapability);

  /// 是否已通过 token 鉴权。
  bool get isAuthed => _authed;

  /// 出站 seq：每连接从 0 单调递增，断线重连由新全量快照重置
  /// （dom-replay.md §2「不做增量续传」）。
  int _outSeq = 0;

  StreamSubscription<dynamic>? _sub;
  Timer? _authTimer;
  bool _closed = false;

  void start() {
    _authTimer = Timer(
      _server.authTimeout,
      () => close(kRelayCloseUnauthorized, '鉴权超时'),
    );
    _sub = channel.stream.listen(
      _onData,
      onDone: _dispose,
      onError: (_) => _dispose(),
    );
  }

  void _onData(dynamic raw) {
    if (_closed) return;
    // 上行只收 JSON 文本帧：远程端→宿主的消息（input/ctrl）都是小体
    // 积控制面数据，二进制帧仅用于宿主→远程端大流量下行（#15）。
    if (raw is! String) {
      close(1003, '仅接受 JSON 文本帧');
      return;
    }
    final envelope = RelayEnvelope.tryDecode(raw);
    if (envelope == null) {
      close(1002, '信封格式错误');
      return;
    }
    if (!_authed) {
      // 收到有效 auth 前不接受任何其他消息。
      _handleAuth(envelope);
      return;
    }
    switch (envelope.type) {
      case RelayMessageType.ping:
        send(RelayChannel.ctrl, RelayMessageType.pong, envelope.data);
      case RelayMessageType.auth:
        close(kRelayCloseUnauthorized, '重复鉴权');
      default:
        _server._dispatch(id, envelope);
    }
  }

  void _handleAuth(RelayEnvelope envelope) {
    final data = envelope.data;
    final token = data is Map ? data['token']?.toString() : null;
    final ok =
        envelope.channel == RelayChannel.ctrl &&
        envelope.type == RelayMessageType.auth &&
        token != null &&
        RelayToken.equals(token, _server._token ?? '');
    if (!ok) {
      send(RelayChannel.ctrl, RelayMessageType.authErr, {'reason': '令牌无效'});
      close(kRelayCloseUnauthorized, '鉴权失败');
      return;
    }
    _authed = true;
    _authTimer?.cancel();
    // 能力协商（#15）：客户端声明的 caps 记到连接上，服务端回显自身
    // 支持清单；此后按客户端能力选择文本/二进制下发。
    final caps = data is Map ? data['caps'] : null;
    if (caps is List) {
      _caps.addAll(caps.whereType<String>());
    }
    send(RelayChannel.ctrl, RelayMessageType.authOk, {
      'clientId': id,
      'caps': [kBinaryCapability],
    });
    _server._notifyAuthed(id);
  }

  void send(RelayChannel channel, RelayMessageType type, Object? data) {
    if (_closed) return;
    final envelope = RelayEnvelope(
      channel: channel,
      type: type,
      seq: _outSeq++,
      data: data,
    );
    this.channel.sink.add(envelope.encode());
  }

  /// 发送 v2 二进制帧（#15）：仅用于大流量下行，payload 为原始字节。
  void sendBinary(
    RelayChannel channel,
    RelayMessageType type,
    Uint8List payload,
  ) {
    if (_closed) return;
    this.channel.sink.add(
      encodeBinaryEnvelope(channel, type, _outSeq++, payload),
    );
  }

  Future<void> close([int code = 1000, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _authTimer?.cancel();
    await channel.sink.close(code, reason);
    _dispose();
  }

  void _dispose() {
    if (!_closed) {
      _closed = true;
      _authTimer?.cancel();
    }
    _sub?.cancel();
    _server._removeClient(id);
  }
}
