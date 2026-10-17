/// CDP 客户端回退实现：web_socket_channel 手写最小客户端。
///
/// 仅覆盖一期所需最小面：`/json/list` 枚举 target、WS JSON-RPC 的
/// `Runtime.evaluate` 与任意方法逃生舱。puppeteer Dart 包对目标应用
/// 实际 CDP 行为出现兼容问题时启用（见 docs/research/host-backend.md
/// 「回退链」）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'cdp_client.dart';

/// 手写最小 [CdpClient]：直接连 page target 的 WebSocket。
class RawCdpClient implements CdpClient {
  RawCdpClient({required this.debugPort, this.host = '127.0.0.1'});

  /// 目标应用调试端口。
  final int debugPort;
  final String host;

  final Map<String, RawCdpPage> _pages = {};
  bool _connected = false;

  @override
  String get implementationName => 'raw-websocket';

  @override
  Future<void> connect() async {
    // 探测 /json/version，确认调试端口存活。
    await _getJson('/json/version');
    _connected = true;
  }

  @override
  Future<List<CdpTargetInfo>> listTargets() async {
    _requireConnected();
    final list = await _getJson('/json/list');
    return [
      for (final entry in list)
        CdpTargetInfo(
          id: entry['id'] as String? ?? '',
          type: entry['type'] as String? ?? '',
          url: entry['url'] as String? ?? '',
          title: entry['title'] as String? ?? '',
        ),
    ];
  }

  @override
  Future<CdpPage> attachTo(CdpTargetInfo target) async {
    _requireConnected();
    // /json/list 条目的 webSocketDebuggerUrl 即 page 级 WS 端点。
    final list = await _getJson('/json/list');
    final entry = list.cast<Map<String, dynamic>?>().firstWhere(
      (e) => e?['id'] == target.id,
      orElse: () => null,
    );
    final wsUrl = entry?['webSocketDebuggerUrl'] as String?;
    if (wsUrl == null) {
      throw StateError('target ${target.id} 无 webSocketDebuggerUrl（已消失？）');
    }
    final channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    await channel.ready;
    final page = RawCdpPage(target, channel);
    _pages[target.id] = page;
    return page;
  }

  @override
  Future<void> close() async {
    for (final page in _pages.values) {
      await page.close();
    }
    _pages.clear();
    _connected = false;
  }

  Future<List<dynamic>> _getJson(String path) async {
    final client = HttpClient();
    try {
      final request = await client.get(host, debugPort, path);
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw StateError('CDP HTTP $path 返回 ${response.statusCode}');
      }
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      return decoded is List ? decoded : [decoded];
    } finally {
      client.close();
    }
  }

  void _requireConnected() {
    if (!_connected) throw StateError('尚未 connect() 到调试端口 $host:$debugPort');
  }
}

/// 基于 page 级 WebSocket 的 JSON-RPC 会话。
class RawCdpPage implements CdpPage {
  RawCdpPage(this.target, this._channel) {
    _subscription = _channel.stream.listen(
      _onMessage,
      onError: _onError,
      onDone: _onDone,
    );
  }

  @override
  final CdpTargetInfo target;

  final WebSocketChannel _channel;
  late final StreamSubscription<dynamic> _subscription;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  @override
  Future<Object?> evaluate(String expression) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
    });
    final exception = result['exceptionDetails'];
    if (exception != null) {
      throw StateError('Runtime.evaluate 页面侧异常：${jsonEncode(exception)}');
    }
    return (result['result'] as Map<String, dynamic>?)?['value'];
  }

  @override
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final message = <String, dynamic>{'id': id, 'method': method};
    if (params != null) message['params'] = params;
    _channel.sink.add(jsonEncode(message));
    return completer.future;
  }

  @override
  Future<void> close() async {
    await _subscription.cancel();
    await _channel.sink.close();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('CDP 连接已关闭'));
      }
    }
    _pending.clear();
  }

  void _onMessage(dynamic data) {
    final message = jsonDecode(data as String) as Map<String, dynamic>;
    final id = message['id'];
    if (id is! int) return; // 事件消息一期不消费。
    final completer = _pending.remove(id);
    if (completer == null) return;
    final error = message['error'];
    if (error != null) {
      completer.completeError(StateError('CDP 错误：${jsonEncode(error)}'));
    } else {
      completer.complete((message['result'] as Map<String, dynamic>?) ?? {});
    }
  }

  void _onError(Object error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  void _onDone() {
    _onError(StateError('CDP WebSocket 已断开'));
  }
}
