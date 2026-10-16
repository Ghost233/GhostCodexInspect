# 宿主中转后端技术选型：Dart 内嵌 vs Node sidecar

> 调研工单：Ghost233/GhostCodexInspect#5（wayfinder 地图 #1 下）。术语见根目录 GLOSSARY.md。
> 结论先行：**推荐 Dart 内嵌**（shelf 系 + puppeteer Dart 包做 CDP 客户端），中转声明为 MacLauncher 的一个 service；Node sidecar 仅在负载实测证明 Dart 栈不足时作为回退。理由与依据见下。

## 一、候选方案对照

### 方案 A：Dart 内嵌（推荐）

后端直接写在 Flutter app 进程内，与 maclauncher_sdk 同进程。

**CDP 客户端有现成包，且质量可用：**

- [`puppeteer` (pub.dev)](https://pub.dev/packages/puppeteer)：Puppeteer 的 Dart 移植，3.26.0（2 个月前发布，持续维护），pub 评分 160/160，423 likes，验证发布者 xaha.dev。关键事实：
  - **包含从 Chrome 官方 [devtools-protocol JSON schema](https://github.com/ChromeDevTools/devtools-protocol) 生成的全量强类型协议 API**（`lib/protocol`，覆盖 page/input/dom/dom_snapshot/target/runtime 等全部域）——"With this API you have access to the entire capabilities of Chrome DevTools"（[API 文档](https://pub.dev/documentation/puppeteer/latest/)）。
  - **明确支持 `puppeteer.connect` 连接已在运行的浏览器实例**，且官方文档明确支持 Flutter Desktop（macOS）场景（["Limitations with Flutter"](https://pub.dev/documentation/puppeteer/latest/) 一节）。这正是我们 attach 到目标应用调试端口的用法——不需要它下载/拉起 Chrome 的那一半功能。
  - 官方示例直接演示了画面流采集：`page.devTools.page.startScreencast(maxWidth:, maxHeight:)` + `onScreencastFrame` 事件流收帧（[API 文档「Capture a screencast」](https://pub.dev/documentation/puppeteer/latest/)）。
  - Input 域（`protocol/input`）提供 `dispatchMouseEvent`/`dispatchKeyEvent` 等可信输入下发，对应 GLOSSARY 的「可信输入」。
- [`webkit_inspection_protocol`](https://pub.dev/packages/webkit_inspection_protocol)：Google 官方仓库（google.dev 发布者），但 1.2.1 已 3 年未更新、130 分，是无类型薄封装。仅作备选。
- 兜底中的兜底：CDP 就是 WebSocket + JSON RPC，我们实际用到的域很少（Runtime.evaluate 注入 rrweb、Input.dispatch*、Page.startScreencast、DOM/DOMSnapshot、Target attach）。即便 puppeteer 包对某个 Electron 特定行为有兼容问题，用 [`web_socket_channel`](https://pub.dev/packages/web_socket_channel)（3.0.3，tools.dart.dev 官方，1.6k likes）手写几百行最小客户端也能覆盖，仍然不需要引入第二语言运行时。

**HTTP/WebSocket 服务端是 Dart 官方生态的强项：**

- [`shelf`](https://pub.dev/packages/shelf) + [`shelf_static`](https://pub.dev/packages/shelf_static)（1.1.3，160 分）：静态伺服远程端单页，官方示例即 `io.serve(createStaticHandler(...), 'localhost', 0)`。
- [`shelf_web_socket`](https://pub.dev/packages/shelf_web_socket)（3.0.0，160 分，12.2M 下载）：`webSocketHandler((webSocket, _) {...})` 一个回调接全部 WS 连接，输出 `WebSocketChannel`，与 CDP 客户端侧同类型，转发管道衔接自然。
- 三者同属 dart-lang/shelf monorepo、tools.dart.dev 验证发布者，维护确定性高。

**与 maclauncher_sdk 同进程集成形态**（依据 [SDK_INTEGRATION.md](https://raw.githubusercontent.com/Ghost233/MacLauncher/main/docs/SDK_INTEGRATION.md)）：

```dart
final sdk = MacLauncherSdk.connect(
  projectId: 'ghost-codex-inspect',
  services: {
    'relay': ServiceCallbacks(
      name: '远程中转',
      onStart: () async => await relay.start(),   // 绑 127.0.0.1 端口、生成 token、连 CDP
      onRecycle: () async => await relay.stop(),  // 释放端口/断开 CDP/踢掉远程端；SDK 明确「回收不是退出」
      onStatus: () async => relay.status(),       // 如实回报；15 秒不更新被标 stale
    ),
  },
);
```

- 回调契约与中转生命周期天然对齐：`onRecycle` 的语义就是「释放端口/进程/连接，不退出应用进程」，恰好是中转 stop 的定义。
- SDK 已内置同一服务 start/recycle 串行化（并发变更快速失败 `busy`），中转侧不需要自己做互斥。
- 同进程意味着：token 生成、端口分配、CDP 连接状态与 Flutter 控制面 UI 之间无需任何 IPC，状态共享是直接的对象引用。

**体积代价：零增量。** Dart AOT 进 Flutter app，无额外运行时。

### 方案 B：Node.js sidecar（不推荐，留作回退）

生态确实最厚：[`chrome-remote-interface`](https://github.com/cyrus-and/chrome-remote-interface)（成熟的 1:1 原始协议绑定）、`ws`、以及后续可换 puppeteer-core。但代价是结构性的：

- **运行时体积**：Node v22.20.0 darwin-arm64 官方发行包 tar.gz 50 MB / tar.xz 26 MB（[nodejs.org/dist/v22.20.0](https://nodejs.org/dist/v22.20.0/)），解压后单 `node` 二进制约 100 MB 量级。打进 Flutter .app 意味着安装包近乎翻倍，且永远背一个需要跟进安全补丁的第二运行时。
- **单文件化方案不成熟**：[Node SEA](https://nodejs.org/api/single-executable-applications.html) 仍是 Stability 1.1（Active development），macOS 上需 postject 注入 blob 并重新 codesign，且只支持单个 CommonJS/ESM 入口脚本，资源与原生 addon 都要绕路。我们只需 ws + 一个 CDP 客户端两个纯 JS 依赖，单脚本打包可行，但整条工具链（bundle → postject → 签名 → 公证）都要自己搭。
- **进程管理与 IPC**：Flutter 主进程要负责 spawn、崩溃看护、端口/stdio 协商、退出清理。SDK 的 `onRecycle` 回收语义下还要多回收一个子进程。所有在 Dart 内嵌方案中「免费」的状态共享，在这里都变成 IPC 协议设计。
- **rrweb 生态优势是假象**：见第二节——rrweb 的记录端运行在目标应用页面内（通过 CDP evaluate 注入的 JS），回放端运行在远程端浏览器内；中转只是转发 JSON 事件，**宿主后端语言根本接触不到 rrweb 代码**。Node 生态最厚的部分恰好是我们用不到的部分。

### 方案 C：Swift / Rust helper（排除）

- Rust 有 [`chromiumoxide`](https://github.com/mattsse/chromiumoxide)：全类型 CDP、async，可连接已运行实例；但 README 自述「current API still lacks some functionality」，且仅支持 tokio 运行时。引入它等于引入第三条工具链 + Flutter↔Rust 的 FFI 或 IPC 桥，相对 Dart 内嵌没有任何收益点。
- Swift 无同等成熟度的 CDP 客户端生态，WS+JSON 全靠手写；Flutter 侧还要走 platform channel。两头都不占便宜。
- 结论：除非未来出现「Dart 性能实测不达标且 Node 也不能接受」的双重失败，否则不考虑。

## 二、关键架构事实：DOM 重绘不依赖宿主语言

依据 [rrweb 官方 README](https://github.com/rrweb-io/rrweb)：rrweb 分为 rrweb-snapshot（DOM 序列化/重建）、record（在页面内记录快照与增量 mutation）、replay（重建并回放事件流）。

在本工具中的部署位置：

| rrweb 组件 | 运行位置 | 如何到达那里 |
|---|---|---|
| record（采集端） | **目标应用页面内** | 宿主经 CDP `Runtime.evaluate` 注入（puppeteer Dart 包即支持 `page.evaluate`） |
| 中转转发 | 宿主中转 | 纯 JSON 事件管道，与语言无关 |
| replay（回放端） | **远程端浏览器** | 远程端静态单页自带（ADR 0001 已定为无框架静态 HTML/JS） |

因此「Node 有 rrweb 同源生态」不构成选型权重。宿主后端在 DOM 重绘模式下只做三件事：注入脚本、转发增量事件（KB 级/秒）、反向转发输入事件到 CDP Input 域。

画面流模式同理：CDP `Page.startScreencast` 直接产出 base64 编码的帧（jpeg/png/webp，协议参数见 [DevTools Protocol Page 域](https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-startScreencast)；puppeteer Dart 的[官方 screencast 示例](https://pub.dev/documentation/puppeteer/latest/)证实该能力在 Dart 侧可用），中转按帧转发即可。

## 三、双模式数据面设计

### 单条 WebSocket，逻辑分通道（推荐）

DOM 增量与画面帧走**同一条 WebSocket**，用消息信封区分通道：

```json
{"ch": "dom",   "data": {...rrweb 增量事件...}}
{"ch": "frame", "ts": 123, "data": "<base64 jpeg>"}
{"ch": "input", "data": {...鼠标/键盘事件...}}      // 远程端 → 宿主方向
{"ch": "ctrl",  "data": {"mode": "screencast"}}     // 模式切换、心跳、鉴权
```

理由：

1. **一次握手一次鉴权**：token 只在连接建立时校验一次，两条连接就要维护两份鉴权状态与断线重连逻辑。
2. **量级允许**：DOM 增量 KB/秒；画面帧按 15-20fps、单帧几十 KB 计约 1-3 MB/s。127.0.0.1 与 LAN 下 WebSocket 单连接吞吐远超此量级，HoL 阻塞对输入延迟的影响在毫秒级。
3. **两模式互斥为主**：GLOSSARY 定义画面流是 DOM 重绘的兜底模式，常态只有一种数据在流，不存在双通道互相挤占的稳态。
4. CDP 自身的 screencast 协议带帧确认（`screencastFrameAck`）流量控制语义，宿主侧可以实现「远程端消费不过来就降帧/丢帧」，背压策略集中在宿主一处，比两条连接各自背压简单。

留一个演进口子：帧数据初期用 base64 JSON（与 CDP 产出同构，零转换），若 LAN 实测带宽紧张，信封协议不变、`ch: "frame"` 的消息体切换为二进制 WebSocket 帧即可。

### Token 鉴权握手设计

约束回顾：默认绑 127.0.0.1，显式开关才绑 LAN IP，token 每次启动随机生成。建议：

1. **生成**：每次中转启动用 CSPRNG 生成 ≥128 bit token（Dart `Random.secure()`）。
2. **分发**：token 通过控制面 UI 展示/复制，拼入访问 URL 的 **fragment**（`http://127.0.0.1:PORT/#t=TOKEN`）——fragment 不进 HTTP 请求、不进服务器日志，避免 token 经静态资源请求泄漏。
3. **握手**：远程端 JS 从 fragment 读出 token，WS 连接建立后第一条消息发送 `{"ch":"ctrl","auth":"TOKEN"}`；宿主在收到有效 auth 前不接受任何其他消息，且设置短超时（如 5 秒）关闭未鉴权连接。也可用 `Sec-WebSocket-Protocol: gci.<token>` 在 Upgrade 时携带，更早拒绝，但子协议方式不利于浏览器端调试，首消息方式足够。
4. **纵深防御**（即便只绑回环）：校验 WS Upgrade 的 `Origin`/`Host` 头，拒绝跨站页面发起的连接（防 DNS rebinding 借浏览器打回环服务）；HTTP 静态伺服只服务已知路径清单，无目录遍历。
5. **绑 LAN 的显式开关**打开时，以上鉴权不变；文档中注明绑 LAN 时 token 即唯一防线，应配合二期隧道使用。

## 四、对二期公网隧道的延展性

结论：**选型与隧道方案正交**，两条隧道都工作在 TCP/HTTP 层，不感知中转用什么语言写。

- **Tailscale**：[`tailscale serve`](https://tailscale.com/docs/features/tailscale-serve) 可把本地服务代理到 tailnet 并自动提供 HTTPS 证书；[Funnel](https://tailscale.com/docs/features/tailscale-funnel) 进一步暴露到公网。中转保持绑 127.0.0.1 不动，隧道在前面终结 TLS，token 鉴权原样保留。这是推荐路径：零代码改动。
- **frp**：[官方 README](https://github.com/fatedier/frp) 显示其支持 HTTP/HTTPS 代理类型、token/OIDC 鉴权、自 v0.50.0 起默认开启 TLS。同样是前置终结，中转无感。
- 若未来要中转自身终结 TLS，Dart 的 `HttpServer.bindSecure`/`SecurityContext` 也支持，不构成功能缺口。

对选型的唯一影响是：隧道方案把「传输安全」整体外包后，Node sidecar 假设中「Node TLS/网络生态更厚」的论点进一步失去权重。

## 五、最终建议

**采用方案 A：Dart 内嵌。**

- CDP 客户端：`puppeteer` Dart 包（只用 `puppeteer.connect` + `lib/protocol` 强类型 API，不用其浏览器下载/拉起功能）。
- 服务端：shelf + shelf_web_socket + shelf_static。
- 集成：中转注册为 MacLauncher service（`relay`），onStart/onRecycle/onStatus 生命周期对齐；与控制面 UI 同进程零 IPC。
- 数据面：单 WS + 通道信封 + 首消息 token 鉴权 + Origin/Host 校验。
- 隧道：二期交给 tailscale serve / frp 前置终结，中转不改动。

**回退链（按序启用）：**

1. puppeteer Dart 包对 Codex app 实际 CDP 行为出现兼容问题 → 退到 `web_socket_channel` 手写最小 CDP 客户端（仅 5 个域），仍是 Dart 内嵌。
2. Dart WS 服务端在画面流负载下实测不达标（预期概率低）→ 才评估 Node sidecar，且只让其做数据面转发，控制面与 SDK 集成仍留在 Flutter 进程。

**不做**：Swift/Rust helper（第三工具链无收益）；Node SEA 打包（Stability 1.1，macOS 签名链复杂）；双 WebSocket 分数据面（增加鉴权与生命周期复杂度，收益不成立）。

## 六、开放问题

1. puppeteer Dart 包对 **Electron 主进程 debug 端口**的实测兼容性（它日常针对 Chrome 测试；Electron 的 `/json` 端点与 Target 结构需在前提校验阶段实测，属一期检查器工单范围）。
2. 画面流帧率/码率在 LAN 下的实测数据，决定是否启用二进制帧优化与动态降帧策略。
3. `puppeteer.connect` 到 Electron 时 browser-level WS 与 page target 的 attach 路径（`Target.attachToTarget` flatten 模式）细节，留待实现工单验证。

## 来源清单

- MacLauncher SDK 集成指南：<https://raw.githubusercontent.com/Ghost233/MacLauncher/main/docs/SDK_INTEGRATION.md>
- puppeteer (Dart)：<https://pub.dev/packages/puppeteer> ；API 文档（含 screencast 示例与 Flutter Desktop 支持说明）：<https://pub.dev/documentation/puppeteer/latest/>
- webkit_inspection_protocol：<https://pub.dev/packages/webkit_inspection_protocol>
- shelf_web_socket：<https://pub.dev/packages/shelf_web_socket> ；shelf_static：<https://pub.dev/packages/shelf_static> ；web_socket_channel：<https://pub.dev/packages/web_socket_channel>
- chrome-remote-interface：<https://github.com/cyrus-and/chrome-remote-interface>
- Node.js SEA 文档：<https://nodejs.org/api/single-executable-applications.html> ；Node v22.20.0 发行体积：<https://nodejs.org/dist/v22.20.0/>
- DevTools Protocol Page 域：<https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-startScreencast>
- rrweb：<https://github.com/rrweb-io/rrweb>
- chromiumoxide (Rust)：<https://github.com/mattsse/chromiumoxide>
- Tailscale Serve / Funnel：<https://tailscale.com/docs/features/tailscale-serve> 、<https://tailscale.com/docs/features/tailscale-funnel>
- frp：<https://github.com/fatedier/frp>
