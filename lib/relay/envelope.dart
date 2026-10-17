/// 通道信封协议（工单 #8）：单条 WebSocket 上复用 dom/frame/input/ctrl
/// 四个逻辑通道，消息带单调递增 seq。协议草案见
/// docs/research/dom-replay.md §2 与 docs/research/host-backend.md §三。
///
/// 信封线格式（JSON 文本帧）：
/// ```json
/// {"v":1,"ch":"dom","t":"inc","seq":42,"ts":1730000000000,"data":{...}}
/// ```
///
/// fflate 压缩接入点（工单 #11，本期不实现）：`batch` 等大数据量消息的
/// `data` 可整体切换为 `{"z":"fflate","b64":"<base64(deflate(payload))>"}`
/// 包装，信封外层字段（v/ch/t/seq/ts）保持不变，远程端见到 `z` 字段先解压
/// 再按原 payload 处理。
library;

import 'dart:convert';

/// 协议版本。
const int kRelayProtocolVersion = 1;

/// 逻辑通道：dom（DOM 重绘增量）、frame（画面流帧）、input（远程端 → 宿主
/// 的可信输入）、ctrl（鉴权、模式切换、心跳等控制消息）。
enum RelayChannel {
  dom,
  frame,
  input,
  ctrl;

  static RelayChannel? tryParse(String name) =>
      RelayChannel.values.asNameMap()[name];
}

/// 信封消息类型：
/// - `meta`：视口宽高/href 等元信息（对应 rrweb Meta 事件）；
/// - `full`：全量快照（新连接一律从全量开始）；
/// - `inc`：单条增量事件；
/// - `batch`：微批聚合的增量事件数组；
/// - `resync`：远程端发现 seq 缺口或处理错误时请求重新发全量；
/// - `ping`/`pong`：应用层心跳；
/// - `auth`/`authOk`/`authErr`：WS 首消息令牌鉴权握手；
/// - `input`：input 通道的可信输入事件（远程端 → 宿主，#11 接通）；
/// - `frame`：frame 通道的画面流帧（宿主 → 远程端，#12 接通）。
enum RelayMessageType {
  meta,
  full,
  inc,
  batch,
  resync,
  ping,
  pong,
  auth,
  authOk,
  authErr,
  input,
  frame;

  static RelayMessageType? tryParse(String name) =>
      RelayMessageType.values.asNameMap()[name];
}

/// 信封格式错误：JSON 非法、缺字段或字段值越界时抛出。
class RelayEnvelopeFormatException extends FormatException {
  RelayEnvelopeFormatException(super.message);
}

/// 一条通道信封。纯 Dart 可测：不依赖 dart:io 与 WebSocket。
class RelayEnvelope {
  RelayEnvelope({
    required this.channel,
    required this.type,
    required this.seq,
    int? ts,
    this.data,
  }) : assert(seq >= 0, 'seq 必须非负'),
       // 宿主/远程端发送时刻（UTC 毫秒）；未提供时取当前时刻。
       ts = ts ?? DateTime.now().toUtc().millisecondsSinceEpoch;

  /// 协议版本，固定为 [kRelayProtocolVersion]。
  final int version = kRelayProtocolVersion;

  /// 逻辑通道。
  final RelayChannel channel;

  /// 消息类型。
  final RelayMessageType type;

  /// 单调递增序号；断线重连后由新的全量快照重置（每连接各自计数）。
  final int seq;

  /// 发送时刻（UTC 毫秒）。
  final int ts;

  /// 消息体：rrweb 事件、事件数组、帧 base64、鉴权令牌等 JSON 可编码对象。
  final Object? data;

  Map<String, Object?> toJson() => {
    'v': version,
    'ch': channel.name,
    't': type.name,
    'seq': seq,
    'ts': ts,
    if (data != null) 'data': data,
  };

  /// 编码为 JSON 文本帧。
  String encode() => jsonEncode(toJson());

  /// 解码 JSON 文本帧；任何格式问题抛 [RelayEnvelopeFormatException]。
  static RelayEnvelope decode(String raw) {
    final Object? json;
    try {
      json = jsonDecode(raw);
    } on FormatException catch (e) {
      throw RelayEnvelopeFormatException('信封不是合法 JSON：${e.message}');
    }
    if (json is! Map) {
      throw RelayEnvelopeFormatException('信封必须是 JSON 对象');
    }

    final v = json['v'];
    if (v != kRelayProtocolVersion) {
      throw RelayEnvelopeFormatException('不支持的协议版本：$v');
    }

    final channel = RelayChannel.tryParse(switch (json['ch']) {
      final String s => s,
      _ => '',
    });
    if (channel == null) {
      throw RelayEnvelopeFormatException('未知通道：${json['ch']}');
    }

    final type = RelayMessageType.tryParse(switch (json['t']) {
      final String s => s,
      _ => '',
    });
    if (type == null) {
      throw RelayEnvelopeFormatException('未知消息类型：${json['t']}');
    }

    final seq = json['seq'];
    if (seq is! int || seq < 0) {
      throw RelayEnvelopeFormatException('seq 必须是非负整数：${json['seq']}');
    }

    final ts = json['ts'];
    if (ts != null && (ts is! int || ts < 0)) {
      throw RelayEnvelopeFormatException('ts 必须是非负整数毫秒：${json['ts']}');
    }

    return RelayEnvelope(
      channel: channel,
      type: type,
      seq: seq,
      ts: (ts as int?) ?? 0,
      data: json['data'],
    );
  }

  /// 解码失败返回 null 的版本（服务端收包路径用，避免异常开销）。
  static RelayEnvelope? tryDecode(String raw) {
    try {
      return decode(raw);
    } on RelayEnvelopeFormatException {
      return null;
    }
  }
}
