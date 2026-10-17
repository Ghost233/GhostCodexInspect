/// 中转绑定地址策略（工单 #8）：默认只绑 127.0.0.1；「允许局域网访问」
/// 开关打开时绑 LAN 网卡 IP（第一个非回环 IPv4）；绝不绑 0.0.0.0。
library;

import 'dart:io';

/// 绑定策略失败：例如开关打开但机器没有可用 LAN 网卡。
class RelayBindException implements Exception {
  RelayBindException(this.message);

  final String message;

  @override
  String toString() => 'RelayBindException: $message';
}

/// 解析中转应绑定的地址。
///
/// - [allowLanAccess] 为 false（默认）：返回 127.0.0.1 回环地址。
/// - [allowLanAccess] 为 true：枚举网卡，返回第一个非回环 IPv4 地址；
///   找不到时抛 [RelayBindException]，绝不退回 0.0.0.0。
Future<InternetAddress> resolveBindAddress({
  required bool allowLanAccess,
}) async {
  if (!allowLanAccess) {
    return InternetAddress.loopbackIPv4;
  }
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  final selected = pickLanAddress(interfaces.expand((i) => i.addresses));
  if (selected == null) {
    throw RelayBindException('「允许局域网访问」已打开，但未找到非回环 IPv4 网卡');
  }
  return selected;
}

/// 纯选择逻辑（可测）：返回第一个非回环 IPv4 地址；没有则返回 null。
/// 注意永不返回 anyIPv4（0.0.0.0）。
InternetAddress? pickLanAddress(Iterable<InternetAddress> addresses) {
  for (final address in addresses) {
    if (address.type == InternetAddressType.IPv4 && !address.isLoopback) {
      return address;
    }
  }
  return null;
}
