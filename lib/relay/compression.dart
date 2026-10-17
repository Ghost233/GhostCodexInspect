/// 信封 payload 压缩（工单 #14 Scope 3，格式见 envelope.dart 头部约定）。
///
/// 动机（#6 真机实测）：rrweb 全量快照 2.86MB（样式表 CSSOM 内联所致），
/// 增量稳态 KB 级。压缩只在大 payload 上启用：
/// - UTF-8 JSON 长度 < [kCompressionMinBytes]：原样透传（压缩不划算，
///   远程端也无需判断解压路径）。
/// - ≥ 阈值：data 替换为 `{"z":"fflate","b64":"<base64(zlib(utf8(json)))>"}`
///   包装；信封外层字段（v/ch/t/seq/ts）不变，中转只透传不解析。
///
/// 远程端用 vendor fflate（`unzlibSync` + `strFromU8`）解压后按原 payload
/// 处理；Dart 侧用 dart:io 的 zlib 编解码，与 fflate 的 zlib 格式互通
/// （RFC 1950 zlib wrapper）。
library;

import 'dart:convert';
import 'dart:io';

/// 包装标记字段名（data 含此字段即为压缩包装）。
const String kCompressionMarkerField = 'z';

/// 压缩算法标记值（远程端按此选择 fflate 解压路径）。
const String kCompressionAlgorithm = 'fflate';

/// 压缩 payload 字段名（base64 编码的 zlib 字节流）。
const String kCompressionPayloadField = 'b64';

/// 压缩启用阈值（UTF-8 JSON 字节数）：小于此值原样透传。
const int kCompressionMinBytes = 4096;

/// 压缩封装 [data]（任意可 JSON 序列化的 payload）。
///
/// 小于 [minBytes] 时原样返回 [data]；否则返回压缩包装 Map。
Object? maybeCompressPayload(Object? data, {int minBytes = kCompressionMinBytes}) {
  if (data == null) return null;
  final bytes = utf8.encode(jsonEncode(data));
  if (bytes.length < minBytes) return data;
  return <String, String>{
    kCompressionMarkerField: kCompressionAlgorithm,
    kCompressionPayloadField: base64Encode(zlib.encode(bytes)),
  };
}

/// 判断 data 是否为压缩包装。
bool isCompressedPayload(Object? data) =>
    data is Map && data[kCompressionMarkerField] == kCompressionAlgorithm;

/// 解压压缩包装，还原原始 payload（JSON 反序列化后的对象）。
///
/// 非压缩包装时原样返回 [data]；包装损坏抛 [FormatException]。
Object? maybeDecompressPayload(Object? data) {
  if (!isCompressedPayload(data)) return data;
  final map = data! as Map;
  final b64 = map[kCompressionPayloadField];
  if (b64 is! String) {
    throw const FormatException('压缩包装缺 b64 字段');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(zlib.decode(base64Decode(b64))));
  } on Object catch (e) {
    throw FormatException('压缩 payload 解压失败：$e');
  }
  return decoded;
}
