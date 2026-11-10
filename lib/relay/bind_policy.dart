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

/// 列出监听范围内的 IPv4 地址，去重并补上本机回环入口。
List<InternetAddress> pickAccessAddresses(
  Iterable<InternetAddress> addresses, {
  required bool allowLanAccess,
}) {
  final result = <String, InternetAddress>{};
  if (allowLanAccess) {
    for (final address in addresses) {
      if (address.type == InternetAddressType.IPv4 &&
          !address.isLoopback &&
          address != InternetAddress.anyIPv4) {
        result[address.address] = address;
      }
    }
  }
  result['127.0.0.1'] = InternetAddress.loopbackIPv4;
  return result.values.toList();
}
