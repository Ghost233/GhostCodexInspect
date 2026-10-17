/// CDP 连接层抽象接口。
///
/// 两种实现收敛到同一接口，方便替换（见 docs/research/host-backend.md）：
/// - `PuppeteerCdpClient`：puppeteer Dart 包（优先）。
/// - `RawCdpClient`：web_socket_channel 手写最小客户端（回退）。
library;

/// 一个 CDP target 的薄描述（对应 `/json/list` 条目 / TargetInfo）。
class CdpTargetInfo {
  const CdpTargetInfo({
    required this.id,
    required this.type,
    required this.url,
    required this.title,
  });

  final String id;
  final String type;
  final String url;
  final String title;

  @override
  String toString() => 'CdpTargetInfo(type=$type, url=$url, title=$title)';
}

/// 判断 target 是否为指定 shell scheme 的页面（目标应用主界面）。
///
/// 规则：`type == 'page'` 且 URL 以 `<scheme>://` 开头
/// （ChatGPT.app 的 shell 为 `app://`，fixture 为 `file://`）。
bool isShellTarget(CdpTargetInfo target, List<String> shellUrlSchemes) {
  if (target.type != 'page') return false;
  return shellUrlSchemes.any((scheme) => target.url.startsWith('$scheme://'));
}

/// 已 attach 到某个 page target 的会话。
abstract class CdpPage {
  /// 所属 target。
  CdpTargetInfo get target;

  /// 在页面主上下文执行表达式并返回按值结果（CDP `Runtime.evaluate`，
  /// `returnByValue: true`）。
  Future<Object?> evaluate(String expression);

  /// 发送任意 CDP 方法（逃生舱，覆盖接口未封装的能力）。
  Future<Map<String, dynamic>> send(
    String method, [
    Map<String, dynamic>? params,
  ]);

  /// 注册页面全局函数 [name]（CDP `Runtime.addBinding`）：页面侧调用
  /// `window[name](jsonString)` 时，返回的流推出该字符串 payload。
  ///
  /// 跨导航存活（DOM 重绘采集器 `__gciEmit` 依赖此语义，工单 #11）。
  /// 流在页面句柄关闭时结束。
  Future<Stream<String>> exposeBinding(String name);

  /// 关闭页面句柄（不断开整个 CDP 连接）。
  Future<void> close();
}

/// CDP 客户端：attach 到调试端口并枚举 target。
abstract class CdpClient {
  /// 实现名（`puppeteer` / `raw-websocket`），用于诊断与回退记录。
  String get implementationName;

  /// 建立到调试端口的连接。
  Future<void> connect();

  /// 枚举全部 target。
  Future<List<CdpTargetInfo>> listTargets();

  /// attach 到指定 target，返回页面会话。
  Future<CdpPage> attachTo(CdpTargetInfo target);

  /// 断开连接（不杀目标应用进程）。
  Future<void> close();
}
