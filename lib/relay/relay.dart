/// 中转（Relay）模块：向远程端转发目标应用画面与反向输入的宿主内服务。
///
/// 实现工单：#8。默认只绑定 127.0.0.1；选型见 docs/research/host-backend.md。
library;

export 'bind_policy.dart';
export 'envelope.dart';
export 'relay_server.dart';
export 'relay_token.dart';
