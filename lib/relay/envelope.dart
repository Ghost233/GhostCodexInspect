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
import 'dart:typed_data';

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
/// - `frame`：frame 通道的画面流帧（宿主 → 远程端，#12 接通）；
/// - `shells`：宿主→远程端的 shell 页面清单（`ch=ctrl`，#16 tab 切换）；
/// - `switchTarget`：远程端→宿主的 shell 切换请求（`ch=ctrl`，#16）。
///
/// ⚠️ 二进制帧（v2）的类型 id 派生自枚举序 + 1：新类型只允许追加在
/// 末尾，禁止中间插入或重排，否则新旧两端解码错位。
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
  frame,

  /// data = {targets: [{id, title, url, primary}], activeId}。
  shells,

  /// data = {targetId}；宿主停当前会话、attach 目标页后重建同类会话。
  switchTarget;

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

/// 能力协商标记（工单 #15 二期）：auth 握手 `data.caps` 声明支持的特性。
/// 客户端 caps 含 [kBinaryCapability] 且服务端回显后，该连接的大流量消息
/// （dom 压缩 payload、frame JPEG）走 v2 二进制帧；未声明则全程文本帧。
const String kBinaryCapability = 'bin.v2';

/// 信封 v2 二进制帧布局（固定头 15 字节 + 原始 payload）：
/// - `[0]`：版本，固定 0x02；
/// - `[1]`：通道 id（[RelayChannel] 枚举序 + 1）；
/// - `[2]`：消息类型 id（[RelayMessageType] 枚举序 + 1）；
/// - `[3..6]`：seq，uint32 小端；
/// - `[7..14]`：ts，int64 小端（UTC 毫秒）；
/// - `[15..]`：payload 原始字节（dom=fflate 压缩的 JSON；frame=JPEG）。
///
/// 控制面消息（auth/ping/输入下发等）永远走文本帧，二进制帧只用于
/// 宿主→远程端的大流量下行。
const int kBinaryHeaderLength = 15;

/// 一条解码后的 v2 二进制信封（payload 保持原始字节，由消费方解释）。
class BinaryEnvelope {
  const BinaryEnvelope({
    required this.channel,
    required this.type,
    required this.seq,
    required this.ts,
    required this.payload,
  });

  final RelayChannel channel;
  final RelayMessageType type;
  final int seq;
  final int ts;
  final Uint8List payload;
}

/// 编码 v2 二进制帧。
Uint8List encodeBinaryEnvelope(
  RelayChannel channel,
  RelayMessageType type,
  int seq,
  Uint8List payload, {
  int? ts,
}) {
  final out = ByteData(kBinaryHeaderLength)
    ..setUint8(0, 2)
    ..setUint8(1, channel.index + 1)
    ..setUint8(2, type.index + 1)
    ..setUint32(3, seq, Endian.little)
    ..setUint64(
      7,
      ts ?? DateTime.now().toUtc().millisecondsSinceEpoch,
      Endian.little,
    );
  return Uint8List.fromList(
    out.buffer.asUint8List().followedBy(payload).toList(growable: false),
  );
}

/// 解码 v2 二进制帧；格式问题抛 [RelayEnvelopeFormatException]。
BinaryEnvelope decodeBinaryEnvelope(Uint8List raw) {
  if (raw.length < kBinaryHeaderLength) {
    throw RelayEnvelopeFormatException('二进制帧短于 15 字节头：${raw.length}');
  }
  final view = ByteData.sublistView(raw);
  final version = view.getUint8(0);
  if (version != 2) {
    throw RelayEnvelopeFormatException('不支持的二进制帧版本：$version');
  }
  final channelId = view.getUint8(1);
  final typeId = view.getUint8(2);
  if (channelId < 1 || channelId > RelayChannel.values.length) {
    throw RelayEnvelopeFormatException('未知通道 id：$channelId');
  }
  if (typeId < 1 || typeId > RelayMessageType.values.length) {
    throw RelayEnvelopeFormatException('未知消息类型 id：$typeId');
  }
  return BinaryEnvelope(
    channel: RelayChannel.values[channelId - 1],
    type: RelayMessageType.values[typeId - 1],
    seq: view.getUint32(3, Endian.little),
    ts: view.getUint64(7, Endian.little),
    payload: Uint8List.sublistView(raw, kBinaryHeaderLength),
  );
}
