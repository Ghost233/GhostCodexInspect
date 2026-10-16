# DOM 重绘全链路方案选型：采集、传输与远端重建

> 调研工单：Ghost233/GhostCodexInspect #3（wayfinder 地图 #1 子工单）
> 日期：2026-10-17
> 范围：纯文档调研，未触碰任何真实目标 app 进程。
> 结论一句话：**采集与重建采用 rrweb（record 侧经 CDP 注入、远端用 `@rrweb/replay` 的 liveMode，不用 rrweb-player），传输为自研薄协议（单条 WebSocket + 序号 + fflate 批量压缩），输入反向用坐标映射 + CDP Input 域。**

## 背景与约束

- 目标：对以 `--remote-debugging-port` 启动的 Electron app（一期 Codex 桌面 app，macOS arm64）经 CDP 接管 shell 页面，在纯静态 HTML/JS 单页（无框架、无构建链，见 [ADR 0001](../adr/0001-remote-client-plain-web.md)）远端重建 DOM 供实时操作。
- 注入方式已定：CDP `Page.addScriptToEvaluateOnNewDocument`。
- 输入反向：远端事件 → CDP `Input` 域（页面内合成事件 `isTrusted=false`，会被拒收，必须经 CDP 下发可信输入）。
- 带宽目标：KB 级/秒。

---

## 1. 采集：自研 MutationObserver vs rrweb vs CDP DOM 域

### 1.1 候选方案

**A. rrweb（@rrweb/record）** — 推荐

rrweb 的 record 侧正是「MutationObserver 增量序列化」的成熟实现，其核心机制（来自官方内部设计文档）：

- **全量序列化**：遍历时以 Node 为单位（含 Text/Comment），给每个节点分配唯一递增 `id`，两侧维护一致的 `id ↔ Node` 映射，增量事件只引用 id。`script` 标签改写为 `noscript` 占位（重放侧不执行 JS，只重放脚本造成的 DOM 变化）。（[serialization 设计文档](https://github.com/rrweb-io/rrweb/blob/master/docs/design/serialization.md)）
- **增量序列化难点已被解决**：
  - MutationObserver 是批量异步回调；rrweb 对新增节点做**延迟序列化 + 去重**（先收集、整批处理完再序列化并去重），并处理「新增后未序列化即被移除」的 dropped node、属性变更在同一回调内只保留最终值（textarea 拖拽 resize 场景防爆量）等边界。（[observer 设计文档](https://github.com/rrweb-io/rrweb/blob/master/docs/design/observer.md)）
  - 表单态：`input`/`change` 事件监听 + 去重；程序赋值不触发 MutationObserver，rrweb 通过 **hook setter** 捕获（自研方案极易漏掉这一点）。radio 同 name 互斥无事件的特例也已处理。
- **CSS 内联**：序列化时从浏览器解析后的 CSSOM 生成内联样式表文本，因此外链样式表（包括 `app://`、内网等远端不可达的地址）的样式内容会随快照一起走——这对 Electron app 场景是关键优点。（[serialization 设计文档](https://github.com/rrweb-io/rrweb/blob/master/docs/design/serialization.md)、[optimize-storage](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/optimize-storage.md)）
- **增量事件类型**（`@rrweb/types` 的 `IncrementalSource` 枚举）：`Mutation, MouseMove, MouseInteraction, Scroll, ViewportResize, Input, TouchMove, MediaInteraction, StyleSheetRule, CanvasMutation, Font, Log, Drag, StyleDeclaration, Selection, AdoptedStyleSheet, CustomElement`。（[packages/types/src/index.ts](https://github.com/rrweb-io/rrweb/blob/master/packages/types/src/index.ts)）
- **shadow DOM**：类型层原生支持（`isShadowHost` / `isShadow` 标记）。（[packages/types/src/index.ts:920-921](https://github.com/rrweb-io/rrweb/blob/master/packages/types/src/index.ts)）
- **iframe**：同源 iframe 自动纳入序列化；跨源 iframe 需 `recordCrossOriginIframes: true`，子框架内也注入 record 脚本，事件经 `postMessage` 汇总到顶层。官方明确给出 **Electron 场景注入方式**：`webPreferences.preload` + `nodeIntegrationInSubFrames: true`——但我们不改目标 app，等价手段就是 CDP `Page.addScriptToEvaluateOnNewDocument`（其语义即「在每个 frame 创建时、页面脚本之前求值」，见 §1.3）。（[cross-origin-iframes 配方](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/cross-origin-iframes.md)）
- **体积控制**（直接决定能否达到 KB/s）：
  - `sampling` 配置：`mousemove: false`（远程操作模式下宿主机鼠标轨迹无需回传）、`scroll: 150`（150ms 节流）、`input: 'last'`（连续输入只记最终值）、`mouseInteraction` 可按类型开关。（[optimize-storage](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/optimize-storage.md)）
  - `packFn`：官方 `@rrweb/packer` 提供基于 fflate 的单事件压缩，重放侧配 `unpackFn`。
  - `slimDOMOptions` 可剔除 script/comment/head 噪音（`headTitleMutations` 可抑制标题动画产生的 mutation 风暴）。（[packages/rrweb-snapshot/src/types.ts](https://github.com/rrweb-io/rrweb/blob/master/packages/rrweb-snapshot/src/types.ts)）
  - 官方还建议整段会话在后端做 deflate 批压，压缩率优于逐事件。（[optimize-storage](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/optimize-storage.md)）
- **SPA 兼容性**：MutationObserver 对 SPA 的所有 DOM 变化天然兼容；rrweb 为录屏场景打磨多年，虚拟列表、动画等元素可用 block class 排除。

**B. 自研 MutationObserver 增量序列化** — 不推荐作为主方案

等价于重写 rrweb record 侧：必须自行解决 §1.1-A 列出的全部边界（批量回调去重、延迟序列化与 id 分配时序、attribute 合并、setter hook、radio 特例、hover 样式、样式表内联、相对路径转绝对）。这些正是设计文档自认「最难的部分」。自研唯一收益是包体与协议完全可控，可作为二期优化方向（按我们协议裁剪 rrweb 源码），一期不值得。

**C. CDP DOM 域 / DOMSnapshot** — 不适合做增量主通道，可做校验辅助

- `DOM.getDocument(depth: -1, pierce: true)` 可取全树（pierce 可穿透 iframe 与 shadow root），增量事件存在（`attributeModified`/`attributeRemoved`/`characterDataModified`/`childNodeInserted`/`childNodeRemoved` 等），**但 `documentUpdated` 事件会使所有 node id 失效**（「Fired when `Document` has been totally updated. Node ids are no longer valid.」），SPA 路由切换即全量失效重来；且该通道不携带样式表内容、表单态等。（[DOM.pdl](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOM.pdl)）
- `DOMSnapshot.captureSnapshot` 返回扁平化 DOM + 白名单 computed style + DOM rects，shadow DOM 被拍平——是**快照**语义、无增量流，适合调试/对账，不适合实时镜像。（[DOMSnapshot.pdl](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOMSnapshot.pdl)）

### 1.2 采集结论

采用 **rrweb record**（npm 包 `@rrweb/record`，或从源码裁剪后内联），经 `Page.addScriptToEvaluateOnNewDocument` 注入目标页面每个 frame。推荐起步配置：

```js
record({
  emit: (event) => /* 经 Runtime.binding 或 console 中转给中继 */,
  sampling: { mousemove: false, scroll: 150, input: 'last' },
  slimDOMOptions: { script: true, comment: true, headTitleMutations: true },
  recordCrossOriginIframes: true, // 若目标页面有跨源 iframe
  recordCanvas: true,             // 见 §3.3
  // packFn 视中继批压策略二选一，见 §2
});
```

### 1.3 注入方式确认

`Page.addScriptToEvaluateOnNewDocument(source, { worldName?, runImmediately? })`：「Evaluates given script in every frame upon creation (before loading frame's scripts)」。注意：默认只影响**之后**创建的文档，对已经存在的页面需配合 `Page.navigate` 刷新或 `runImmediately: true`（experimental）。OpenCLI 的 `OPENCLI_CDP_INIT_SCRIPT` 环境变量正是该能力的封装（「run it on every new document of the connected page」），可作参考实现。（[Page.pdl:562-578](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl)、[OpenCLI docs/advanced/cdp.md](https://github.com/jackwener/OpenCLI/blob/main/docs/advanced/cdp.md)）

事件出页通道：注入脚本无法直接连 WebSocket 到任意源（受目标页面 CSP 约束），稳妥做法是 CDP `Runtime.addBinding` 暴露一个宿主侧 binding 函数，record 的 `emit` 调 binding 把事件推给中继（这也是 Puppeteer 生态注入 rrweb 的常见做法，见 cross-origin-iframes 配方中的 `exposeFunction` 示例）。

---

## 2. 传输协议草案（单条 WebSocket）

rrweb 官方 live mode 即为此场景设计：远端 `Replayer` 配 `liveMode: true` + `startLive()`，之后每收到一个事件调 `replayer.addEvent(event)`；官方建议引入缓冲基线 `startLive(Date.now() - BUFFER_MS)`（如 1000ms）吸收网络与节流延迟。（[live-mode 配方](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/live-mode.md)）

在官方语义之上加一层自研薄信封：

```
Envelope (JSON 或二进制帧):
{
  v: 1,                 // 协议版本
  seq: <uint64>,        // 单调递增，断线重连后由快照重置
  t: "meta" | "full" | "inc" | "batch" | "resync" | "ping/pong",
  ts: <ms>,             // 宿主侧发送时刻
  payload: <rrweb event | event[] | base64(fflate(event[]))>
}
```

要点：

1. **握手**：远端连接后，中继先强制目标页生成一次全量快照（rrweb 提供 `record.takeFullSnapshot()`），依次发 `meta`（视口宽高/href，对应 rrweb Meta 事件）→ `full`（FullSnapshot）→ 之后 `inc`/`batch` 增量流。新连接一律从全量开始，不做增量续传（简单可靠）。
2. **序号与缺口**：`seq` 单调递增；远端发现缺口或处理错误 → 回 `resync` 请求 → 中继重新发全量。WebSocket 本身保序（RFC 6455），缺口只可能来自中继丢弃（背压策略）或进程重启。
3. **分帧与批量**：rrweb 事件天然小（增量通常百字节级）。中继做微批（如 50ms 或 32KB 先到先发）聚合成 `batch`，降低帧开销；鼠标移动已关闭，最大流量来自 Mutation。
4. **压缩**：两选一——(a) `packFn: pack`（fflate 逐事件）实现最简单；(b) 中继对 batch payload 整体 fflate/deflate，压缩率更好（官方建议）。WebSocket 的 permessage-deflate 扩展（RFC 7692）是第三选项，但浏览器端对发送方向控制弱，且对高频小消息收益不稳定；建议先用 (b)，不够再叠加。
5. **背压**：中继侧设发送队列上限；超限则丢弃增量并直接发新全量快照（对实时镜像，丢中间态安全）。rrweb 事件流本身无状态依赖跨事件引用（id 引用由全量建立），但**丢增量可能使 id 引用悬空**（增量中新增节点后续被引用），因此丢弃策略必须以「整段丢弃 + 全量重建」为粒度，不可丢单个事件。
6. **反向通道**：同一条 WebSocket 复用，远端 → 中继消息 `{t: "input", ...}`（见 §4），中继翻译为 CDP 调用。

---

## 3. 远端重建

### 3.1 用 `@rrweb/replay` 的 Replayer，不用 rrweb-player

- **rrweb-player** 是带进度条/控制条的「录像播放器」UI 包装，面向事后回放；我们要的是实时镜像 + 操作接管，应直接用 **`@rrweb/replay` 的 `Replayer`**（`liveMode: true`）。（[rrweb guide](https://github.com/rrweb-io/rrweb/blob/master/guide.md)、[live-mode 配方](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/live-mode.md)）
- 重建在 **sandboxed iframe** 中进行：`sandbox="allow-same-origin"`，禁止脚本、表单提交、弹窗。当前版本 `rebuild()` 已强制该边界，须用 `rebuildIntoSandboxedIframe()` / `createSandboxedIframe()`。（[sandbox 设计文档](https://github.com/rrweb-io/rrweb/blob/master/docs/design/sandbox.md)）
- 保真度来源：
  - **样式**：样式表以文本内联进快照，远端直接生效；hover 通过额外注入的 `.:hover` 类模拟（重建侧自动处理）。（[replay 设计文档](https://github.com/rrweb-io/rrweb/blob/master/docs/design/replay.md)）
  - **滚动**：滚动为独立增量源（`IncrementalSource.Scroll`，节流可配），重放时恢复元素 scrollTop/scrollLeft；全量快照含 `initialOffset`（见 `fullSnapshotEvent` 类型）。
  - **表单态**：Input 增量源回放 value/checked；序列化时把 `value` 等视图态写入属性。
  - **相对路径**：序列化时转绝对路径，避免在远端 iframe 上下文中解析错误。
  - **字体**：`IncrementalSource.Font` 增量源 + 样式内联覆盖了 CSS 中的 @font-face 文本；但**字体/图片二进制若走 `app://` 等远端不可达 scheme，仍是盲区**——这是 Electron 场景与常规 Web 录屏的差异点，需要中继做资源代理（拦截 `app://` 请求转发为 http）或序列化侧 dataURL 内联，列为开放问题（§6）。

### 3.2 操作模式与回放模式的差异

我们不只是「看录像」：远端用户的鼠标/键盘是要回传的输入源。因此重建侧需要：

- 在 replay iframe 上监听真实用户事件（click/mousemove/wheel/keydown），转发给中继（§4）。sandbox 为 `allow-same-origin`（非同源隔离），父页面可以直接给 iframe contentDocument 挂监听器。
- 关闭 rrweb 自带的「模拟回放鼠标」视觉元素（liveMode 下宿主机本无鼠标事件流入，因我们 `mousemove: false`）。
- 远端视口尺寸 ≠ 宿主窗口尺寸时，用 CSS transform scale 等比缩放 iframe，输入坐标反向除以缩放系数（§4.2）。

### 3.3 canvas / WebGL 与原生盲区

- **canvas**：rrweb 默认不记录 canvas 内容。开启 `recordCanvas: true` 后支持**图像快照录制，最高 15fps**，产物为 dataURL（可配 `dataURLOptions: { type: 'image/webp', quality: 0.6 }`）——即「canvas 截位图嵌入」**官方支持且可行**，WebGL 画布同理（截的是合成后的像素）。重放侧需 `UNSAFE_replayCanvas: true`（会给 replay iframe 加 `allow-scripts`，放弃沙箱脚本保护——官方明确标注风险，仅用于可信数据）。另有 canvas-webrtc 插件可走 RTC 流式传输，一期不必要。（[canvas 配方](https://github.com/rrweb-io/rrweb/blob/master/docs/recipes/canvas.md)）
- **原生菜单、系统对话框、Electron 原生 UI**：完全不在 DOM 内，DOM 重绘模式结构性不可见——这正是术语表中「画面流模式（Screencast Mode）」作为兜底存在的理由（见 [GLOSSARY.md](../../GLOSSARY.md)）。一期建议：识别到目标 app 弹出原生对话框时（可通过 CDP `Page.javascriptDialogOpening` 等事件或窗口状态变化探测）提示用户切换画面流模式。

---

## 4. 输入反向：远端事件 → CDP Input 域

### 4.1 CDP Input 域事实（一手来源）

- `Input.dispatchMouseEvent`：`type ∈ {mousePressed, mouseReleased, mouseMoved, mouseWheel}`；**x/y 为「相对于 main frame 视口的 CSS 像素」**（「relative to the main frame's viewport in CSS pixels」）；`modifiers` 位掩码 Alt=1 Ctrl=2 Meta=4 Shift=8；`buttons` 位掩码 Left=1 Right=2 Middle=4；wheel 用 `deltaX/deltaY`（CSS 像素）。（[Input.pdl:164-207](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)）
- `Input.dispatchKeyEvent`：`type ∈ {keyDown, keyUp, rawKeyDown, char}`，可带 `key`/`code`/`windowsVirtualKeyCode`/`text`/`modifiers`。（[Input.pdl:96-127](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)）
- `Input.insertText(text)`：「emulates inserting text that doesn't come from a key press, for example an emoji keyboard or an IME」——向当前焦点元素插入文本，是输入正文的首选（对中文等 IME 输入尤其重要；注意标注为 experimental）。（[Input.pdl:140-146](https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl)）
- 经 CDP 下发的事件是 **trusted**（`isTrusted=true`），这正是工单要求的可信输入路线；参考实现 codex-desktop-cdp 验证了这条链路在 ChatGPT/Codex 桌面 app 上可用：定位目标（`/json/list` 中 `type==="page"` 且 `url` 以 `app://` 开头）→ 聚焦 `.ProseMirror[contenteditable="true"]` → `Input.insertText` 输入 → `Input.dispatchKeyEvent` 发 Enter。（[codex-desktop-cdp docs/core-backend-call.md](https://github.com/yorkartur/codex-desktop-cdp/blob/main/docs/core-backend-call.md)）

### 4.2 映射设计要点

1. **首选坐标映射，选择器映射为备**。DOM 重建是高保真视觉镜像，远端点击坐标（iframe 内 CSS px）除以缩放系数后即为目标页视口 CSS px，直接喂 `dispatchMouseEvent`。**选择器路线脆弱**（SPA 动态类名、重建 DOM 与真实 DOM 的细微差异都会断），只在需要「语义化操作」的高级功能（如自动化脚本）时作为补充：远端命中测试得到元素 → 生成 CSS 选择器 → 宿主侧 `document.querySelector().getBoundingClientRect()` 取中心点 → 仍走坐标下发。
2. **坐标系与 DPR**：CDP 坐标就是 CSS px，`devicePixelRatio` 不参与换算（DPR 只在截图/画面流模式的位图尺寸中相关）。真正的换算是：远端 iframe 显示缩放系数 s（视口不匹配时）→ `targetX = clientX_in_iframe / s`。macOS Retina 下目标窗口 innerWidth 本身即 CSS px，与 CDP 一致。
3. **鼠标**：`mousemove`（远端 50-100ms 节流，hover 态需要）→ `mouseMoved`；`mousedown/up` → `mousePressed/Released`（带 `button`、`clickCount`，双击 clickCount=2）；`wheel` → `mouseWheel`，注意 DOM `deltaMode` 归一（line/page 模式需乘行高换算为 px）。
4. **键盘**：可打印字符与 IME 合成结果走 `insertText`；功能键/快捷键（Enter、Esc、Cmd+C 等）走 `dispatchKeyEvent`（rawKeyDown + keyUp，带 `key`/`code`/`modifiers`；macOS 上 Cmd → Meta=4）。远端须拦截页面默认行为（如 Cmd+C 复制远端页面）并把事件透传。
5. **焦点**：`insertText` 作用于目标页**当前焦点元素**，因此点击序列必须先下发（点击即聚焦）；纯键盘输入前可用 `Runtime.evaluate` 确认/校正焦点（参考实现对 composer 显式 focus）。
6. **点击 vs rrweb 的输入录制不冲突**：宿主机无人操作，`sampling.mousemove=false` 只影响「宿主鼠标轨迹回传」，不影响远端输入下发。

---

## 5. 参考实现梳理

### codex-desktop-cdp（yorkartur）

- 验证了完整 CDP 链路在 Codex（ChatGPT 桌面 app，Electron）上的可行性：`/Applications/ChatGPT.app/Contents/MacOS/ChatGPT --remote-debugging-port=9222` 启动，`${endpoint}/json/list` 选 `type==="page"` 且 `url.startsWith("app://")` 的 shell target，`Input.insertText` + `Input.dispatchKeyEvent` 下发。（[README](https://github.com/yorkartur/codex-desktop-cdp)、[core-backend-call.md](https://github.com/yorkartur/codex-desktop-cdp/blob/main/docs/core-backend-call.md)）
- 关键教训：① 明确警告「This is UI automation, not a stable API contract」——选择器随 app 版本漂移，需做健康检查与降级；② 发送路径规则：当本地 UI 本身可能持有焦点时，机械式「粘贴 + 回车」会把文本送回错误的窗口——我们的 DOM 重绘模式输入始终经 CDP 定向到目标 page target，天然规避此问题；③ 安全边界：CDP 端口不暴露到网络，中继默认绑回环地址（与 GLOSSARY 一致）。

### OpenCLI（jackwener）

- **工单引用的 `docs/advanced/electron.md` 在当前 main 分支不存在**（`docs/advanced/` 下仅有 android-chrome/cdp/download/rate-limiter-plugin/remote-chrome 五篇）。最接近的 SOP 是 [docs/advanced/cdp.md](https://github.com/jackwener/OpenCLI/blob/main/docs/advanced/cdp.md)：
  - Electron/Chromium 以 `--remote-debugging-port=9222` 启动；若 CDP WebSocket 客户端带 Origin 头（浏览器场景），需 `--remote-allow-origins="*"`——我们的中继是宿主内服务端连接、不带 Origin，不需要此 flag。
  - `OPENCLI_CDP_ENDPOINT` 指定端点后自动请求 `/json` 选 target，可用 `OPENCLI_CDP_TARGET` 子串收窄——与 codex-desktop-cdp 的 target 选择逻辑一致，可抄。
  - `OPENCLI_CDP_INIT_SCRIPT` = 对连接页每个新文档注入指定 JS 文件，即 `Page.addScriptToEvaluateOnNewDocument` 的封装，直接印证了我们的注入路线。

---

## 6. 选型结论与开放问题

### 结论

| 环节 | 选型 | 理由 |
|---|---|---|
| 采集 | **rrweb `@rrweb/record`**，经 CDP `addScriptToEvaluateOnNewDocument` 注入 | 增量序列化的全部硬边界（mutation 去重、setter hook、样式内联、shadow DOM/iframe）已被解决；自研=重写它；CDP DOM 域增量通道 id 易整体失效且无样式内容 |
| 传输 | **自研薄信封**（seq + meta/full/inc/batch/resync）跑在**单条 WebSocket** 上，batch 级 fflate 压缩 | rrweb 事件模型天然适配流式推送（官方 live mode 即 WebSocket 场景）；压缩与缺口恢复策略简单可靠 |
| 重建 | **`@rrweb/replay` Replayer（liveMode），不用 rrweb-player** | player 是录像 UI；Replayer + `startLive(Date.now()-BUFFER)` 即实时镜像；sandboxed iframe 顺带解决脚本安全 |
| 输入反向 | **坐标映射为主**（iframe CSS px ÷ 缩放系数 → `Input.dispatchMouseEvent`），键盘文本走 `Input.insertText`、功能键走 `dispatchKeyEvent` | CDP 坐标即 CSS px，DPR 无需参与；选择器路线脆弱只作补充 |
| canvas | `recordCanvas: true` + webp 截帧（≤15fps），重放侧 `UNSAFE_replayCanvas` | 官方支持位图截帧嵌入；WebGL 同法；注意沙箱保护降级 |
| 原生 UI 盲区 | 结构性感知 + 提示切画面流模式 | DOM 重绘模式无法覆盖原生菜单/对话框，属预期内 |

### 开放问题

1. **`app://` 资源代理**：样式表文本已内联，但 CSS 引用的字体/图片 URL（`app://` scheme）远端不可达。需中继实现 scheme 代理（把快照中的 `app://` URL 改写为中继 http 端点）或采集侧 dataURL 内联（体积代价）。Codex app 的实际资源引用方式待真机验证（属后续集成工单）。
2. **跨源 iframe 是否真实存在**：`recordCrossOriginIframes` 要求子框架也注入（addScriptToEvaluateOnNewDocument 每 frame 生效，可行），但若子框架有严格 CSP 阻止 binding/通信需验证。
3. **`insertText` 的 experimental 稳定性**：长期可用性依赖 Chromium 版本；备用方案是 `dispatchKeyEvent` 的 `char` 事件逐字符下发（对 IME 组合输入支持差）。
4. **rrweb 包体与无构建链的兼容**：远程端是纯静态无构建链，`@rrweb/replay` 需以 ESM CDN/预打包单文件形式伺服（官方提供 `https://cdn.rrweb.com/replay/current/dist/replay.js` ESM 资产，可 vendor 进仓库）；注入侧 record 脚本同理需预打包为单文件字符串。
5. **canvas 高频动画的带宽**：15fps webp 截帧在 KV 级/秒预算内可能超标，需按画布尺寸实测，必要时降帧/降质或对活跃 canvas 局部切画面流。

## 来源清单

- rrweb guide（安装/record/replay 包拆分、CDN ESM 资产）：https://github.com/rrweb-io/rrweb/blob/master/guide.md
- rrweb 内部设计：serialization / observer / replay / sandbox：https://github.com/rrweb-io/rrweb/tree/master/docs/design（正文引用了各单篇）
- rrweb 配方：optimize-storage / live-mode / canvas / cross-origin-iframes：https://github.com/rrweb-io/rrweb/tree/master/docs/recipes
- rrweb 事件类型定义（EventType、IncrementalSource、shadow 标记）：https://github.com/rrweb-io/rrweb/blob/master/packages/types/src/index.ts
- Chrome DevTools Protocol（PDL 源）：Input https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Input.pdl ；Page https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/Page.pdl ；DOM https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOM.pdl ；DOMSnapshot https://github.com/ChromeDevTools/devtools-protocol/blob/master/pdl/domains/DOMSnapshot.pdl
- 参考实现：https://github.com/yorkartur/codex-desktop-cdp （README 与 docs/core-backend-call.md）
- OpenCLI CDP 适配：https://github.com/jackwener/OpenCLI/blob/main/docs/advanced/cdp.md
- WebSocket 协议：RFC 6455（保序帧）；RFC 7692（permessage-deflate，备选压缩层）
