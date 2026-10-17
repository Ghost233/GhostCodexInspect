import 'dart:convert';
import 'dart:math';

/// 中转访问令牌：每次中转启动时用 CSPRNG 生成（≥128 bit），经 URL
/// fragment 分发给远程端（fragment 不进 HTTP 请求与服务器日志），页面建立
/// WebSocket 后首消息携带鉴权。设计见 docs/research/host-backend.md §三。
class RelayToken {
  RelayToken._();

  /// 令牌字节数：16 字节 = 128 bit。
  static const int byteLength = 16;

  /// 生成新令牌：base64url 编码（22 字符），可直接放入 URL fragment。
  static String generate({Random? random}) {
    final rng = random ?? Random.secure();
    final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 常量时间比较，避免时序侧信道泄露令牌前缀。
  static bool equals(String a, String b) {
    final ba = utf8.encode(a);
    final bb = utf8.encode(b);
    var diff = ba.length ^ bb.length;
    final n = ba.length < bb.length ? ba.length : bb.length;
    for (var i = 0; i < n; i++) {
      diff |= ba[i] ^ bb[i];
    }
    return diff == 0;
  }
}
