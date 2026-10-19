/// DOM 重绘会话（工单 #11）：宿主侧编排。
///
/// 绑定一个已 attach 的 [CdpPage]（目标应用 shell 页面）与一个运行中的
/// [RelayServer]：
/// - 注入采集器（[buildCollectorSource]），事件经 `__gciEmit` binding 回传；
/// - 回传批次分类后经 dom 通道广播：meta → `meta`、全量快照 → `full`、
///   增量微批 → `batch`；
/// - 消费远程端消息：ctrl `resync` → 页面侧强制全量快照；input `input` →
///   CDP Input 域可信事件（见 input_dispatcher.dart）。
library;

import 'dart:async';

import '../cdp/cdp_client.dart';
import '../cdp/viewport_override.dart';
import '../relay/compression.dart';
import '../relay/envelope.dart';
import '../relay/relay_server.dart';
import 'dom_collector.dart';
import 'file_chooser_guard.dart';
import 'input_dispatcher.dart';

/// DOM 重绘会话状态快照（宿主 UI / 诊断用）。
class DomSessionStatus {
  const DomSessionStatus({
    required this.active,
    required this.batchesReceived,
    required this.envelopesSent,
    required this.inputsDispatched,
    required this.lastError,
  });

  final bool active;

  /// 采集器回传的批次数。
  final int batchesReceived;

  /// 已向远程端广播的信封数。
  final int envelopesSent;

  /// 已下发的可信输入数。
  final int inputsDispatched;

  /// 最近一次错误（分类/下发失败等），无则 null。
  final String? lastError;
}

/// DOM 重绘会话。生命周期由宿主管理：[start] 幂等，[stop] 幂等。
class DomSession {
  DomSession({
    required this.page,
    required this.relay,
    this.collectorSource,
    this.compressionMinBytes = kCompressionMinBytes,
    this.onSwitchRequested,
  });

  /// 目标页面（已 attach 的 shell 会话）。
  final CdpPage page;

  /// 运行中的中转。
  final RelayServer relay;

  /// 注入脚本源码；null 时 [start] 从 vendor 路径加载（tool 脚本注入
  /// 测试源码时传参）。
  final String? collectorSource;

  /// dom 通道 payload 压缩阈值（UTF-8 字节，#14）：真机全量快照 2.86MB，
  /// 压缩后远程端用 fflate 解压；0 = 全部压缩（测试用），
  /// 大数 = 实际关闭。默认 [kCompressionMinBytes]。
  final int compressionMinBytes;

  /// 远程端请求切换 shell 页面（ctrl `switchTarget`，工单 #16）时的
  /// 回调，参数为目标 id。会话自身不处理切换（要换 page），由宿主
  /// 编排层停本会话并重建。
  final void Function(String targetId)? onSwitchRequested;

  StreamSubscription<String>? _bindingSub;
  FileChooserGuard? _fileChooserGuard;
  String? _lastError;
  int _batchesReceived = 0;
  int _envelopesSent = 0;
  int _inputsDispatched = 0;
  /// 是否已对页面应用视口覆盖（stop 时据此恢复）。
  bool _viewportOverridden = false;
  bool _started = false;

  /// 首份全量快照到达时完成（验收与断线重连检测用）。
  Completer<void> _firstFull = Completer<void>();

  /// 等待首份全量快照到达。
  Future<void> get firstFullSnapshot => _firstFull.future;

  bool get isActive => _started;

  DomSessionStatus status() => DomSessionStatus(
    active: _started,
    batchesReceived: _batchesReceived,
    envelopesSent: _envelopesSent,
    inputsDispatched: _inputsDispatched,
    lastError: _lastError,
  );

  /// 启动采集与转发。幂等。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 1. binding 先于注入注册，消除页面早期 emit 的竞态。
    final payloads = await page.exposeBinding(kEmitBindingName);
    _bindingSub = payloads.listen(
      _onCollectorBatch,
      onError: (Object e) => _lastError = 'binding 流错误：$e',
    );

    // 2. 中转的客户端消息（resync / input）转本会话消费；新客户端鉴权
    //    成功时触发 resync，让晚到的远程端立即拿到 meta+full（工单 #11）。
    relay.onClientMessage = _onClientMessage;
    relay.onClientAuthed = _onClientAuthed;

    // 3. 注入采集器：当前文档立即 evaluate；addScriptToEvaluateOnNewDocument
    //    覆盖未来导航。
    final source = collectorSource ?? await loadCollectorSource();
    await page.send('Page.enable');
    // 文件对话框拦截守卫（#20）：原生文件框拦下，远程端提示回本机。
    _fileChooserGuard = FileChooserGuard(page: page, relay: relay);
    await _fileChooserGuard!.start();
    await page.send('Page.addScriptToEvaluateOnNewDocument', {
      'source': source,
    });
    await page.evaluate(source);
  }

  /// 停止转发并做页面侧清理（best-effort）：停采集器、摘除全局句柄。
  /// 页面已死/已导航时清理 evaluate 失败忽略。幂等。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    if (_viewportOverridden) {
      _viewportOverridden = false;
      try {
        await clearViewportOverride(page);
      } catch (_) {
        // 页面可能已断开；覆盖随 CDP 会话死亡自动回收
      }
    }
    await _bindingSub?.cancel();
    _bindingSub = null;
    if (relay.onClientMessage == _onClientMessage) {
      relay.onClientMessage = null;
    }
    if (relay.onClientAuthed == _onClientAuthed) {
      relay.onClientAuthed = null;
    }
    await _fileChooserGuard?.stop();
    _fileChooserGuard = null;
    try {
      await page.evaluate(
        '(function(){'
        'var c = window.__gciCollector;'
        'if (c && typeof c.stop === "function") { try { c.stop(); } catch (e) {} }'
        'try { delete window.__gciCollector; } catch (e) {}'
        'try { delete window.$kResyncFunctionName; } catch (e) {}'
        'window.__gciCollectorInstalled = false;'
        '})()',
      );
    } catch (_) {
      // 页面已不可达：CDP 会话死亡后注入与 binding 自动回收（实测），无需处理。
    }
  }

  /// 采集器回传一批事件（JSON 数组字符串）→ 分类 → dom 通道广播。
  void _onCollectorBatch(String payloadJson) {
    _batchesReceived++;
    final ClassifiedEvents classified;
    try {
      classified = classifyEventBatch(payloadJson);
    } on FormatException catch (e) {
      _lastError = '采集批次非法：${e.message}';
      return;
    }
    for (final meta in classified.meta) {
      _broadcastDom(RelayMessageType.meta, meta);
    }
    for (final full in classified.full) {
      _broadcastDom(RelayMessageType.full, full);
      if (!_firstFull.isCompleted) _firstFull.complete();
    }
    if (classified.inc.isNotEmpty) {
      _broadcastDom(RelayMessageType.batch, classified.inc);
    }
  }

  void _broadcastDom(RelayMessageType type, Object? data) {
    relay.broadcast(
      RelayChannel.dom,
      type,
      maybeCompressPayload(data, minBytes: compressionMinBytes),
      // v2 客户端（#15）：zlib 压缩的 JSON 原始字节，免 base64+JSON 包装。
      binaryPayload: compressPayloadBytes(data),
    );
    _envelopesSent++;
  }

  /// 远程端消息：resync（重发 meta+full）与 input（可信输入下发）。
  /// resync 权威通道是 `ctrl`（控制面，与鉴权/心跳同通道，见 envelope.dart
  /// 与 ws-client.js 头部协议注释）；`dom` 通道宽容受理以兼容演进期实现。
  void _onClientMessage(int clientId, RelayEnvelope envelope) {
    switch ((envelope.channel, envelope.type)) {
      case (RelayChannel.dom, RelayMessageType.resync):
      case (RelayChannel.ctrl, RelayMessageType.resync):
        _resync();
      case (RelayChannel.ctrl, RelayMessageType.switchTarget):
        // #16：切换请求透传给宿主编排层；targetId 非法时丢弃。
        final targetId = switch (envelope.data) {
          {'targetId': final String id} when id.isNotEmpty => id,
          _ => null,
        };
        if (targetId != null) onSwitchRequested?.call(targetId);
      case (RelayChannel.ctrl, RelayMessageType.setViewport):
        // 远程端「自适应」视口跟随（2026-10-19）：覆盖目标页视口后
        // 触发全量快照，远程端按新尺寸重建
        final size = parseViewportRequest(envelope.data);
        if (size == null) break;
        unawaited(() async {
          await applyViewportOverride(page, size.width, size.height);
          _viewportOverridden = true;
          await _resync();
        }().catchError((Object e) {
          _lastError = '$e';
        }));
      case (RelayChannel.input, RelayMessageType.input):
        _dispatchClientInput(envelope.data);
      default:
        break; // ping/pong 等由中转自处理或忽略
    }
  }

  /// 新客户端鉴权成功：重发 meta+full（一期全局广播，不做单端定向）。
  void _onClientAuthed(int clientId) => _resync();

  /// 触发页面侧全量快照重发（断线重连 / 远程端发现 seq 缺口）。
  Future<void> _resync() async {
    // 新一轮 full 到达时应再次完成首快照等待语义：重置 completer 供调用方
    // 重新 await（重连场景）。
    if (_firstFull.isCompleted) _firstFull = Completer<void>();
    try {
      await page.evaluate(
        'window.$kResyncFunctionName && window.$kResyncFunctionName()',
      );
    } catch (e) {
      _lastError = 'resync 触发失败：$e';
    }
  }

  Future<void> _dispatchClientInput(Object? data) async {
    try {
      final payload = validateInputPayload(data);
      await dispatchInput(page, payload);
      _inputsDispatched++;
    } on InputPayloadException catch (e) {
      _lastError = '输入 payload 被拒：${e.message}';
    } catch (e) {
      _lastError = '输入下发失败：$e';
    }
  }
}
