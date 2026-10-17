# ChatGPT.app（Codex）CDP 接管实测报告（#4）

实测时间：2026-10-17 22:07（探针原始数据：`docs/research/real-probe-20261017-220759.md`，
由 `tool/real_machine_probe.dart` 采集，attach 模式，未重启目标，全部注入带清理）。
目标版本：26.1013.31256（build 20586）——注意比 #2 快照（26.1007.71326）新，
应用会自动更新，版本相关结论需按版本复核。

## 逐问结论

### 1. `--remote-debugging-port=9238` 是否被加固拦截？——**未拦截，CDP 完全可用**

`ElectronAsarIntegrity` + hardened runtime 不影响路线 A。调试端口正常开放，
`curl http://127.0.0.1:9238/json/version` 就绪（`tool/restart_target_debug.sh`
的就绪检测即依赖此）。对照 northpole.security 加固 cookbook 的拦截特征，本应用未启用
调试端口防护。

### 2. shell 页面形态——**3 个 shell page，主窗口 URL 为 `app://-/index.html`**

15 个 target 分类：`browser:1, page:3, webview:2, other:8, service_worker:1`。
3 个 shell page（scheme `app://`）：

| URL | 角色推断 |
|---|---|
| `app://-/index.html` | **主窗口**（title=ChatGPT，视口 1280×1024，dpr 1） |
| `app://-/detached-window.html?initialRoute=%2Fdetached-window` | 分离窗口（用户把会话拖成独立窗口） |
| `app://-/index.html?initialRoute=%2Favatar-overlay` | 头像浮层小窗 |

**重要修正（影响 #11/#12 已交付代码）**：`findShellTarget` 的「单一 shell」假设
不成立——主窗口与浮层同为 `app://-/index.html`，仅靠 scheme 过滤会命中多个。
主窗口判据应加「无 `initialRoute` 参数」或按视口尺寸最大者。已开后续工单处理。

webview target（非 page，不进 shell 枚举）：`https://chatgpt.com/?source=codex_app_embedded`
（内嵌 ChatGPT 网页内容）与 `codex-sandbox://*.web-sandbox.oaiusercontent.com`
（内联可视化沙箱）。`codex-sandbox://` scheme 证实存在，但用于 sandbox webview
而非 shell。

### 3. 注入存活性 / evaluate / insertText——**全部可行**

- `Page.addScriptToEvaluateOnNewDocument`：受理并返回 identifier，可正常 remove（未留驻）。
- `Runtime.addBinding`：页面侧调用回传宿主 OK（rrweb 采集器的 `__gciEmit` 通道成立）。
- `Runtime.evaluate`：只读勘察全部返回（见第 5/6 问）。
- `Input.insertText`：生效（离屏临时 input 实测值 `probe`）。
- `Input.dispatchMouseEvent`：**真机未测**（点击真实 UI 有副作用风险），
  fixture 链路已证明（#11/#12 E2E），真机首次使用建议先在用户监督下验证。

**CSP 不阻挡 CDP 注入**：页面有严格 CSP meta（`default-src 'none'`、
`script-src 'self' 'sha256-…' 'wasm-unsafe-eval' …`），但 CDP 的 evaluate /
addScriptToEvaluateOnNewDocument / addBinding 在 CSP 之外执行，实测全部成功——
注入路线不受 CSP 约束。

### 4. 主进程调试是否可达——**未实测（也不需要）**

target 列表有 `browser` 级 target，但路线 A 只需 renderer 能力，主进程 eval
（≈spawn shell）属于不必要的攻击面扩张。安全设计按「只 attach page target」收敛，
本项留作已知未验证项记录。

### 5. `app://` 资源引用方式——**CSSOM 全部可访问，rrweb 样式内联路线成立**

54 个样式表全部可读取 `cssRules`（无 SecurityError 拦截）——#3 遗留的
「`app://` 样式远端不可达」疑问解除：rrweb 采集时会把 CSSOM 内联进快照/增量
事件，远端 Replayer 不需要访问 `app://` 资源。字体走 `font-src 'self' data:`，
字体内嵌数据会随快照走（这也是快照偏大的原因之一，见 screencast.md 的带宽分析）。

### 6. 跨源 iframe——**存在 1 个**：`https://cdn.platform.openai.com/deployments/dil/v14/runner.html`

CSP `frame-src` 白名单放行。注入脚本运行在主框架，跨源 iframe 内部 DOM 对
主框架 JS 不可见（同源策略）——rrweb 重建时该区域为盲区，由画面流模式兜底
（与 #3 的原定分工一致）。codex-sandbox webview 同理（独立 target）。

### 7. `Input.insertText` 在 Chromium 155——**可用**（实测生效，见第 3 问）

备用 `dispatchKeyEvent`（rawKeyDown/keyUp + `text:'\r'`）已在 #11 实现并测试，
中文输入法场景走 insertText 即可。

### 8. puppeteer Dart 包 attach Electron——**兼容，无回退**

puppeteer 实现一次连接成功（`fellBack=false`）。raw-websocket 回退实现保留作保险。

## 遗留与后续

- **多 shell 选择策略**（主窗口 vs detached-window vs avatar-overlay）→ 后续适配工单。
- 主进程调试可达性：有意未验证，安全设计不依赖。
- 版本漂移：应用自动更新频繁（两周内 26.1007→26.1013），选择器/结构类结论需
  按版本复核；协议层（CDP 域）结论稳定。
