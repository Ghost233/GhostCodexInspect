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

/// 判断 target 是否为**主 shell 页面**（目标应用主窗口，工单 #14 / #4 实测）。
///
/// #4 实测（docs/research/codex-cdp-probe.md 结论 2）：目标应用有多个
/// `app://` shell page——主窗口 `app://-/index.html`、分离窗口
/// `detached-window.html?initialRoute=…`、头像浮层
/// `?initialRoute=/avatar-overlay`。非主窗口一律带 `initialRoute` 查询参数，
/// 故判据 = shell 命中 且 URL 无 `initialRoute` 参数。
/// fixture（`file://`，无查询参数）天然满足。
bool isPrimaryShellTarget(CdpTargetInfo target, List<String> shellUrlSchemes) {
  if (!isShellTarget(target, shellUrlSchemes)) return false;
  final uri = Uri.tryParse(target.url);
  if (uri == null) return true; // 解析失败宽容视为无参数（保守不丢 target）
  return !uri.queryParameters.containsKey('initialRoute');
}

/// 画面流一帧（CDP `Page.screencastFrame` 事件）。
class ScreencastFrameData {
  const ScreencastFrameData({
    required this.data,
    required this.sessionId,
    required this.metadata,
  });

  /// base64 编码的图像数据（JPEG/PNG，取决于 startScreencast 的 format）。
  final String data;

  /// 帧会话号，回执 `Page.screencastFrameAck` 时原样带回。
  final int sessionId;

  /// 原始元信息（offsetTop/pageScaleFactor/deviceWidth/deviceHeight 等）。
  final Map<String, dynamic> metadata;
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

  /// 画面流帧事件流（CDP `Page.screencastFrame`）。仅在 `Page.startScreencast`
  /// 之后有事件；每帧处理后须回执 `Page.screencastFrameAck`（ack 流控，
  /// 工单 #12）。
  Stream<ScreencastFrameData> get screencastFrames;

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
