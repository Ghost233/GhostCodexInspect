/// CDP 连接层：Chrome DevTools Protocol attach、target 枚举与方法桥接。
///
/// 实现工单：#10。客户端选型见 docs/research/host-backend.md（puppeteer Dart
/// 包优先，web_socket_channel 最小客户端为回退）。
library;

export 'cdp_client.dart';
export 'cdp_connector.dart';
export 'puppeteer_cdp_client.dart';
export 'raw_cdp_client.dart';
