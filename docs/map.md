# Ghost Codex Inspect 项目地图（归档）

> 本文档归档自 GitHub Issue [#1](https://github.com/Ghost233/GhostCodexInspect/issues/1)（wayfinder 地图），归档时间 2026-10-18，归档时 #7–#16 全部交付。
> 归档后该 issue 已关闭；后续决策记录改用 `docs/adr/`，长期词汇用 `GLOSSARY.md`（见 docs/agents/domain.md）。
> 若开启新一波工作，可新建地图 issue 并把本文档作为历史参照。

---

## Destination

一期可运行 MVP：宿主端 Flutter 桌面应用（macOS arm64）对目标应用 `/Applications/ChatGPT.app`（Codex 已并入，Electron，见 #2）完成带参启动、CDP 接管、检查与中转；远程端为纯静态 web 单页，支持 **DOM 重绘模式**（常态远程操作）与 **画面流模式**（兜底）双模式；仅局域网/本机 + token 鉴权。架构对「目标应用」通用，一期只交付 ChatGPT.app（Codex）适配。

## Notes

领域：Electron 应用 CDP 注入与远程接管。术语以根目录 `GLOSSARY.md` 为准。

每个会话应使用的 skill：`research`（research 工单）、`prototype`（原型工单）、`grilling` + `domain-modeling`（默认）、`macos-ui-standards`（Flutter UI 实现时）。

长期约束与偏好：
- **不得重启或干扰本机 codex CLI**（正在支撑其他项目开发）。
- **ChatGPT.app 只能带参重启一次**（不能反复启动）：真机实测统一走 `tool/real_machine_probe.dart`（attach 已运行实例、一遍采全 #4/#6 数据、可重复 attach），提交 `88af129`。
- 只编译 macOS arm64；仅 macOS 桌面。
- 远程端不用 Flutter（DOM 重建需要真实 DOM，见 ADR 0001）。
- 启动器接入 MacLauncher：依赖 `maclauncher_sdk`（git 依赖 `Ghost233/MacLauncher` 的 `packages/maclauncher_sdk`，锁 commit `368ee8d`）。
- 中转默认绑 `127.0.0.1`；「允许局域网访问」为显式开关，打开时绑 LAN 网卡 IP（不绑 `0.0.0.0`）；token 每次宿主启动随机生成。
- 单一 Flutter app package，不建 monorepo；注入/CDP 逻辑在 `lib/` 内分层。
- 调研基线：OpenCLI Electron SOP（github.com/jackwener/OpenCLI）+ codex-desktop-cdp（github.com/yorkartur/codex-desktop-cdp）。

已锁定前提（两轮 grilling 结论）：注入目标 = Codex 桌面端（非 CLI；Codex 已并入 ChatGPT.app，bundle id `com.openai.codex`，Chromium 155，`ElectronAsarIntegrity` 开启 → 仅路线 A 可行，见 #2）；一期范围 = DOM 重绘 + 画面流双免权限版；UI 四模块 = 启动器 / 检查器 / 中转台 / 远程视图本机只读预览；后端与 web 技术选型开放调研。

## Decisions so far

<!-- 索引：每张已关闭工单一行 -->

- [安装 Codex 桌面 app 并完成 Electron 前提校验](https://github.com/Ghost233/GhostCodexInspect/issues/2) — Codex 已并入 `/Applications/ChatGPT.app`（bundle id `com.openai.codex`，arm64，v26.1007.71326，Chromium 155.0.8059.40 框架重命名为 `Codex Framework.framework`）；`ElectronAsarIntegrity` 开启，asar 重打包路线不可行；shell scheme 为 `app` / `codex-sandbox`。

- [DOM 重绘全链路方案选型：采集、传输与远端重建](https://github.com/Ghost233/GhostCodexInspect/issues/3) — rrweb 采集与重建（record 经 `Page.addScriptToEvaluateOnNewDocument` 注入，远端 `@rrweb/replay` Replayer liveMode）；自研薄传输协议（单 WS + seq + meta/full/inc/batch/resync 信封 + fflate 批量压缩）；输入反向坐标映射（CSS px → `Input.dispatchMouseEvent`，文本 `Input.insertText`）；canvas 走 recordCanvas webp 截帧。详见 `docs/research/dom-replay.md`。
- [宿主中转后端技术选型：Dart 内嵌 vs Node sidecar](https://github.com/Ghost233/GhostCodexInspect/issues/5) — Dart 内嵌：puppeteer Dart 包做 CDP 客户端 + shelf 系做中转与静态伺服，中转注册为 MacLauncher `relay` service；Node sidecar 仅作实测回退。详见 `docs/research/host-backend.md`。
- [宿主脚手架与 MacLauncher SDK 接入](https://github.com/Ghost233/GhostCodexInspect/issues/7) — 提交 `defe35f`：Flutter macOS 脚手架（bundle id `com.ghost233.ghostcodexinspect`）、`maclauncher_sdk` 钉在 `368ee8d`、`LauncherConnection` 生命周期封装（幂等 connect / pending-approval 降噪 / states 广播流）、`maclauncher.json`（relay 服务）、分层目录桩（launcher/inspector/relay/cdp/ui）；analyze 零问题、冒烟测试与 debug 启动验证通过。
- [中转后端：token、WebSocket 与通道信封](https://github.com/Ghost233/GhostCodexInspect/issues/8) — 提交 `af948f8`：权威线格式 `{v,ch,t,seq,ts,data}` 确立，四通道 `dom/frame/input/ctrl`；首消息 `{ch:ctrl,t:auth,data:{token}}` 鉴权、失败/超时 4401；URL fragment `#t=<token>`；默认绑 `127.0.0.1`、LAN 开关取首个非回环 IPv4 绝不 `0.0.0.0`；Host 只比主机名；onStatus 如实回报、onRecycle 幂等；`LauncherConnection.startRelay({allowLanAccess})/stopRelay()`；29 例 relay 测试过。
- [远程端单页骨架与 rrweb 资产 vendor](https://github.com/Ghost233/GhostCodexInspect/issues/9) — 提交 `2179d36`：静态单页（顶栏双模式切换）+ `@rrweb/replay` 2.1.1 官方 ESM vendor（`assets/web/vendor/`）+ Replayer liveMode 入口 + 坐标换算工具（node --test 6/6）+ headless Chrome 实测优雅降级；信封已对齐 #8 权威线格式。
- [启动器与检查器核心：目标检测、带参启动、CDP attach](https://github.com/Ghost233/GhostCodexInspect/issues/10) — 提交 `55118df`：TargetProfile 适配重命名框架、`--remote-debugging-port=9238` 可配置、`ELECTRON_RUN_AS_NODE` 环境坑防御；CdpClient 抽象（puppeteer 主实现实测一次成功 + web_socket_channel raw 回退）；fixture 全链路实测通过；发现 ChatGPT.app 已自动更新到 26.1013.31256（build 20586）。
- [DOM 重绘模式端到端切片（一期曳光弹）](https://github.com/Ghost233/GhostCodexInspect/issues/11) — 提交 `9a4adfa` + 加固 `76909c4`：采集器经典脚本注入（剥 export 正则须按行锚定，防误吃字符串内嵌 sourceMappingURL）+ `CdpPage.exposeBinding`（Runtime.addBinding，puppeteer/raw 双实现）+ `DomSession` 编排（meta/full/batch 广播、resync 权威走 ctrl 通道双通道宽容受理、`RelayServer.onClientAuthed` 晚到客户端立即补全量）+ 输入反向（mouse/wheel/text/key → CDP Input trusted）+ 远程端 overlay 捕获层。fixture 全链路实测：协议级 + 真 headless Chrome Replayer 重建、远端点击/打字回灌生效。fflate 压缩未上（LAN JSON 帧已够，留给 #6）。
- [画面流模式端到端切片](https://github.com/Ghost233/GhostCodexInspect/issues/12) — 提交 `39c1734`：`Page.startScreencast`（JPEG q60、ack 流控）→ frame 通道 base64 文本帧；`frame/meta` 广播视口元信息作坐标基准；晚到客户端补种 meta + `captureScreenshot` 合成帧；两会话互斥占用中转回调（模式切换=停一个起一个）；`CdpPage.screencastFrames` 双实现。fixture E2E：≈10.7fps、远端点击/打字回灌生效。踩坑：页签 hidden 时 clientWidth=0 需 ResizeObserver 重排、`e.button` 数值须映射为 CDP 字符串。base64→二进制帧与档位校准留 #6；fileChooser 拦截留 #4。
- [宿主 UI 四模块整合与 macos-ui-standards 验收](https://github.com/Ghost233/GhostCodexInspect/issues/13) — 提交 `a3e288d`：HomeShell 224 侧栏四模块（启动器/检查器/中转台/远程视图）+ HostController 编排层（SDK/检测/带参启动/CDP 探测/中转生命周期/互斥会话，cdpConnector 可注入替身）+ 远程端 `ro=1` 只读预览（宿主 previewUrl 追加 `&ro=1`，app.js 跳过输入捕获层、ScreencastView readOnly，双向防御）；中转台含 token/带 token URL 一键复制、远程端列表、LAN 开关（运行中切换=重启换令牌）；真机操作均弹确认；macos-ui-standards 验收：docs/design.md 角色映射 + docs/screenshots/ticket13/ 八张 golden 截图（golden 方案因屏幕录制权限缺失而采用，字体走 FontLoader+tester.runAsync）。90 例测试全过、analyze 零问题。

- **#4/#6（真机实测，2026-10-17）**：路线 A 实证可行——9238 未被加固拦截；shell 共 3 个，主窗口判据=无 `initialRoute`；严格 CSP 不约束 CDP 注入；样式表 CSSOM 全可访问；`Input.insertText` 可用；puppeteer Dart 无回退；主进程调试有意未验证。画面流选型=startScreencast q60+`everyNthFrame=4` 限帧（~10-15fps、2-4MB/s）；一期 base64，二期二进制帧；rrweb 全量 2.86MB→fflate。适配收尾见 #14。报告 `docs/research/codex-cdp-probe.md`、`screencast.md`

- **真机只读 DOM 演示**（b095b5d + 0dea207，2026-10-18）：首 full 到达 + Replayer 重建主 shell + 30s 采样 +17 信封 inputs=0，通过。加固回补 #11：glue v2 令牌化守卫（stale 布尔卡死事故修复）+ DomSession.stop() 页面侧清理 + rrweb replay 容错 `<webview>`。
- **#14 真机适配收尾**（77b30f9+aa4fe5f）：多 shell 主窗口判别（无 initialRoute）；everyNthFrame 默认 4；dom 通道 fflate 压缩（z/b64 包装，阈值 4096B）；fixture 端口分离 9240 + isDebugPortAlive 预检（2026-10-17 错连事故修复）；真机只读画面流演示 10.2fps 通过。二进制帧拆二期 #15。

- **#15（二期二进制帧，797aead）**：信封 v2 = 15 字节固定头 + 原始 payload（frame 直接 JPEG、dom 为 zlib JSON）；auth caps 协商 bin.v2，中继按连接能力分发、旧客户端自动回落文本帧；实测带宽比 v2/v1=0.744（≈base64 理论 0.75）。宿主 UI 真机走查与 MacLauncher 实机联调（connected）亦已完成（f1baaac，沙盒 network.client 授权与包内 web 根目录解析两起修复）。

| #16 远程端多 shell 页签切换（2026-10-18，694dab0） | ctrl `shells`/`switchTarget` 信封（二进制 id 末尾追加）+ 会话 onSwitchRequested 透传 + HostController 校验后切换重建 + 远程端页签栏；顺带实锤修复 pubspec 资产目录不递归子目录与 loadCollectorSource 解析。真机走查验证 3 shell 切换。 |

## Implementation wave（已排期）

开发期验证策略：实现切片在**最小 Electron 替身 fixture**（`tool/fixture/`，调试端口 9240，与真机 9238 分离）上验收；真机验证走 attach 模式（`tool/real_machine_probe.dart`、`tool/demo_real_screencast.dart`），不重启不关闭目标实例。

- ~~#7 宿主脚手架与 MacLauncher SDK 接入~~ ✅ 已完成（defe35f）
- ~~#8 中转后端：token、WebSocket 与通道信封~~ ✅ 已完成（af948f8）
- ~~#9 远程端单页骨架与 rrweb 资产 vendor~~ ✅ 已完成（2179d36）
- ~~#10 启动器与检查器核心：目标检测、带参启动、CDP attach~~ ✅ 已完成（55118df）
- ~~#11 DOM 重绘模式端到端切片（一期曳光弹）~~ ✅ 已完成（9a4adfa + 76909c4）
- ~~#12 画面流模式端到端切片~~ ✅ 已完成（39c1734）
- ~~#13 宿主 UI 四模块整合与 macos-ui-standards 验收~~ ✅ 已完成（a3e288d）
- ~~#4/#6 真机实测~~ ✅ 已完成（2026-10-17 那次带参重启后 attach 探针 9/9；报告 docs/research/codex-cdp-probe.md、screencast.md）
- ~~#14 真机适配收尾~~ ✅ 已完成（77b30f9 + aa4fe5f）——真机只读画面流演示 10.2fps 通过
- #15 二期二进制帧与信封 v2 ✅（带宽比 0.744，旧客户端回落验证通过）
- #16 远程端多 shell 页签切换 ✅（694dab0，真机 3 shell 切换走查通过）——另已落地 deploy-release 发布体系（scripts/release.sh + release.yml DMG 管线，5607866）。地图无在排工单

## Not yet specified

- 公网访问：隧道层（tailscale / frp+TLS / SSH）或独立 relay 服务的形态。
- 真远程桌面重档：CGEvent 键鼠注入（Swift helper）+ 辅助功能/输入监控/屏幕录制权限。
- DOM 模式盲区处理策略：原生菜单、系统对话框、canvas/WebGL 内容（canvas 截位图嵌入待评估）。
- 多目标应用扩展：Cursor、ChatGPT 等第二个适配何时进入。
- asar 注入（路线 B）：仅当路线 A 被 Codex 加固拦截时才立项。

## Out of scope

- codex CLI（终端 TUI）的注入或接管——非 Electron，CDP 路线不适用。
- Windows / Linux / Intel Mac 支持。
- 对非自有、未授权目标应用的任何注入操作。







