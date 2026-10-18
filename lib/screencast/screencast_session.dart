/// 画面流会话（工单 #12）：兜底模式宿主侧编排。
///
/// 绑定一个已 attach 的 [CdpPage] 与一个运行中的 [RelayServer]：
/// - `Page.startScreencast`（JPEG 推送式，ack 流控）→ 帧经 frame 通道
///   `frame` 信封广播（base64 文本帧，#6 实测后再定是否切二进制）；
/// - 启动时经 frame 通道 `meta` 信封广播视口元信息
///   `{viewportWidth, viewportHeight, dpr}`（远程端按此做坐标映射，
///   与 JPEG 像素尺寸解耦）；
/// - 消费远程端 input 通道 `input` 信封 → CDP Input 域可信事件（与 #11
///   的 DOM 模式共用 input_dispatcher.dart）。
///
/// 一期互斥约定：中转的客户端消息回调（onClientMessage/onClientAuthed）
/// 同一时刻只能被一个会话占用。DOM 模式与画面流模式切换 = 停一个起
/// 一个（宿主 UI 在工单 #13 落实该策略）；[start] 发现回调已被占用时
/// 抛 [StateError]。
library;

import 'dart:async';
import 'dart:convert';

import '../cdp/cdp_client.dart';
import '../dom/input_dispatcher.dart';
import '../relay/envelope.dart';
import '../relay/relay_server.dart';

/// 画面流会话状态快照（宿主 UI / 诊断用）。
class ScreencastSessionStatus {
  const ScreencastSessionStatus({
    required this.active,
    required this.framesSent,
    required this.inputsDispatched,
    required this.lastFrameAt,
    required this.lastError,
  });

  final bool active;

  /// 已广播的帧数。
  final int framesSent;

  /// 已下发的可信输入数。
  final int inputsDispatched;

  /// 最近一帧广播时刻（UTC 毫秒），无则 null。
  final int? lastFrameAt;

  /// 最近一次错误，无则 null。
  final String? lastError;
}

/// 画面流会话。生命周期由宿主管理：[start] 幂等，[stop] 幂等。
class ScreencastSession {
  ScreencastSession({
    required this.page,
    required this.relay,
    this.quality = 60,
    this.everyNthFrame = 4,
    this.maxWidth,
    this.maxHeight,
  });

  /// 目标页面（已 attach 的 shell 会话）。
  final CdpPage page;

  /// 运行中的中转。
  final RelayServer relay;

  /// JPEG 质量（0-100，默认 60；档位校准待 #6 实测数据）。
  final int quality;

  /// 每隔几帧推一帧（默认 4：#6 真机实测全推时源端 40-62fps、12-21MB/s，
  /// 限帧 4 后 ~10-15fps、2-4MB/s；fixture E2E 等需要精确帧率的场景显式传 1）。
  final int everyNthFrame;

  /// 帧最大宽/高（CDP 侧缩放；null = 不限制）。
  final int? maxWidth;
  final int? maxHeight;

  StreamSubscription<ScreencastFrameData>? _frameSub;
  String? _lastError;
  int _framesSent = 0;
  int _inputsDispatched = 0;
  int? _lastFrameAt;
  bool _started = false;

  /// 首帧到达时完成（验收用）。
  Completer<void> _firstFrame = Completer<void>();

  /// 等待首帧到达。
  Future<void> get firstFrame => _firstFrame.future;

  bool get isActive => _started;

  ScreencastSessionStatus status() => ScreencastSessionStatus(
    active: _started,
    framesSent: _framesSent,
    inputsDispatched: _inputsDispatched,
    lastFrameAt: _lastFrameAt,
    lastError: _lastError,
  );

  /// 启动画面流。幂等；中转回调被另一会话占用时抛 [StateError]。
  Future<void> start() async {
    if (_started) return;
    if (relay.onClientMessage != null || relay.onClientAuthed != null) {
      throw StateError('中转消息回调已被另一会话占用（一期互斥约定：先 stop 另一个会话）');
    }
    _started = true;

    relay.onClientMessage = _onClientMessage;
    // 晚到的远程端鉴权成功后：补发视口 meta + 抓一帧静态画面（页面静止时
    // screencast 不产帧，否则远程端会一直停在占位层）。
    relay.onClientAuthed = _onClientAuthed;

    // 帧订阅先于 startScreencast，消除首帧竞态。
    _frameSub = page.screencastFrames.listen(
      _onFrame,
      onError: (Object e) => _lastError = '帧流错误：$e',
    );

    await page.send('Page.enable');

    // 视口元信息：远程端坐标映射的基准（与 JPEG 像素尺寸解耦）。
    await _broadcastViewportMeta();

    await page.send('Page.startScreencast', {
      'format': 'jpeg',
      'quality': quality,
      'everyNthFrame': everyNthFrame,
      if (maxWidth != null) 'maxWidth': maxWidth,
      if (maxHeight != null) 'maxHeight': maxHeight,
    });
  }

  /// 停止画面流（不动目标页面与中转本身）。幂等。
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    await _frameSub?.cancel();
    _frameSub = null;
    try {
      await page.send('Page.stopScreencast');
    } catch (e) {
      _lastError = '停止 screencast 失败：$e';
    }
    if (relay.onClientMessage == _onClientMessage) {
      relay.onClientMessage = null;
    }
    if (relay.onClientAuthed == _onClientAuthed) {
      relay.onClientAuthed = null;
    }
    // 重启后首帧语义重新生效。
    if (_firstFrame.isCompleted) _firstFrame = Completer<void>();
  }

  /// 广播视口元信息（frame 通道 meta 信封，JSON 字符串 payload）。
  Future<void> _broadcastViewportMeta() async {
    try {
      final meta = await page.evaluate(
        'JSON.stringify({viewportWidth: window.innerWidth, '
        'viewportHeight: window.innerHeight, dpr: window.devicePixelRatio})',
      );
      relay.broadcast(RelayChannel.frame, RelayMessageType.meta, meta);
    } catch (e) {
      _lastError = '视口元信息读取失败：$e';
    }
  }

  /// 晚到客户端：补 meta + 用 captureScreenshot 合成一帧（静态页面
  /// screencast 不产帧，保证远程端立即有画面）。
  void _onClientAuthed(int clientId) {
    unawaited(_reseedClient());
  }

  Future<void> _reseedClient() async {
    await _broadcastViewportMeta();
    try {
      final result = await page.send('Page.captureScreenshot', {
        'format': 'jpeg',
        'quality': quality,
      });
      final data = result['data'];
      if (data is String) {
        relay.broadcast(
          RelayChannel.frame,
          RelayMessageType.frame,
          {'data': data, 'metadata': const {'synthetic': true}},
          // v2 客户端（#15）：JPEG 原始字节，免 base64。
          binaryPayload: base64Decode(data),
        );
      }
    } catch (e) {
      _lastError = '补帧失败：$e';
    }
  }

  /// 帧到达：广播后立即 ack（ack 流控：不回执源侧就停推）。
  void _onFrame(ScreencastFrameData frame) {
    relay.broadcast(
      RelayChannel.frame,
      RelayMessageType.frame,
      {'data': frame.data, 'metadata': frame.metadata},
      // v2 客户端（#15）：JPEG 原始字节，免 base64。
      binaryPayload: base64Decode(frame.data),
    );
    _framesSent++;
    _lastFrameAt = DateTime.now().toUtc().millisecondsSinceEpoch;
    if (!_firstFrame.isCompleted) _firstFrame.complete();
    // ack 不回等待，失败记入诊断（下一帧自然会再触发或停推）。
    unawaited(
      page
          .send('Page.screencastFrameAck', {'sessionId': frame.sessionId})
          .catchError((Object e) {
            _lastError = '帧回执失败：$e';
            return <String, dynamic>{};
          }),
    );
  }

  /// 远程端消息：仅消费 input（画面流模式的坐标基准是视口 CSS 像素，
  /// 与 DOM 模式同一 payload schema）。
  void _onClientMessage(int clientId, RelayEnvelope envelope) {
    if (envelope.channel == RelayChannel.input &&
        envelope.type == RelayMessageType.input) {
      _dispatchClientInput(envelope.data);
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
