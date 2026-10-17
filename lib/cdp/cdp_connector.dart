/// CDP 连接器：优先 puppeteer，实测不兼容时回退 web_socket_channel
/// 最小客户端。两种实现收敛到 [CdpClient] 接口，对上层透明。
library;

import 'cdp_client.dart';
import 'puppeteer_cdp_client.dart';
import 'raw_cdp_client.dart';

/// attach 结果：已连接的客户端与实际生效的实现名。
class CdpConnection {
  const CdpConnection({
    required this.client,
    required this.fellBack,
    this.puppeteerError,
  });

  /// 已 connect() 的客户端。
  final CdpClient client;

  /// 是否发生了回退（puppeteer 失败 → raw-websocket）。
  final bool fellBack;

  /// puppeteer 失败原因（未回退时为 null）。
  final Object? puppeteerError;

  String get implementationName => client.implementationName;
}

/// 按回退链 attach 到调试端口。
///
/// [preferRaw] 为 true 时跳过 puppeteer 直接使用回退实现（用于测试回退路径）。
Future<CdpConnection> connectCdp({
  required int debugPort,
  String host = '127.0.0.1',
  bool preferRaw = false,
}) async {
  if (!preferRaw) {
    final puppeteerClient = PuppeteerCdpClient(debugPort: debugPort, host: host);
    try {
      await puppeteerClient.connect();
      // 实测兼容性检查：连接成功不代表 target 枚举可用，先枚举一次。
      await puppeteerClient.listTargets();
      return CdpConnection(client: puppeteerClient, fellBack: false);
    } on Object catch (error) {
      await puppeteerClient.close();
      final rawClient = RawCdpClient(debugPort: debugPort, host: host);
      await rawClient.connect();
      return CdpConnection(
        client: rawClient,
        fellBack: true,
        puppeteerError: error,
      );
    }
  }
  final rawClient = RawCdpClient(debugPort: debugPort, host: host);
  await rawClient.connect();
  return CdpConnection(client: rawClient, fellBack: true);
}

/// 在已连接客户端上找到目标应用的 shell 页面 target。
///
/// 未找到时抛出带全部 target 清单的异常，便于诊断。
CdpTargetInfo findShellTarget(
  List<CdpTargetInfo> targets,
  List<String> shellUrlSchemes,
) {
  for (final target in targets) {
    if (isShellTarget(target, shellUrlSchemes)) return target;
  }
  throw StateError(
    '未找到 shell 页面 target（scheme：${shellUrlSchemes.join(', ')}）。'
    '现有 target：\n  ${targets.join('\n  ')}',
  );
}
