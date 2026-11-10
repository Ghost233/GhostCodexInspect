/// 中转绑定地址策略（工单 #8）：默认只绑 127.0.0.1；「允许局域网访问」
/// 开关打开时监听所有 IPv4 接口（0.0.0.0）。
library;

import 'dart:io';

/// 解析中转应绑定的地址。
///
/// - [allowLanAccess] 为 false（默认）：返回 127.0.0.1 回环地址。
/// - [allowLanAccess] 为 true：返回 0.0.0.0，不依赖特定网卡。
Future<InternetAddress> resolveBindAddress({
  required bool allowLanAccess,
}) async {
  if (!allowLanAccess) {
    return InternetAddress.loopbackIPv4;
  }
  return InternetAddress.anyIPv4;
}

/// 纯选择逻辑（可测）：返回第一个非回环 IPv4 地址；没有则返回 null。
/// 注意永不返回 anyIPv4（0.0.0.0）。
InternetAddress? pickLanAddress(Iterable<InternetAddress> addresses) {
  for (final address in addresses) {
    if (address.type == InternetAddressType.IPv4 &&
        !address.isLoopback &&
        address != InternetAddress.anyIPv4) {
      return address;
    }
  }
  return null;
}
