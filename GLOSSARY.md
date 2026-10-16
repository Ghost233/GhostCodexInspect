# GhostCodexInspect

GhostCodexInspect 是对 Electron 桌面应用做注入、检查与远程接管的工具。一期目标应用是 ChatGPT.app（Codex 桌面端已并入其中，bundle id `com.openai.codex`，进程用户数据目录为 `~/Library/Application Support/Codex`）。本文件记录该上下文的领域词汇。

## 语言

**目标应用（Target App）**：被注入与接管的第三方 Electron 桌面应用。被安装或被启动不等于可被接管。

**注入（Injection）**：在不修改目标应用源码的前提下获得其界面控制能力的手段总称。启动参数路线为首选，asar 重打包为后备。
_避免使用_：破解、hook

**CDP 接管（CDP Takeover）**：通过 Chrome DevTools Protocol 连接目标应用调试端口，获得页面评估、输入下发与画面采集能力。

**调试端口（Debug Port）**：目标应用以调试参数启动后暴露的 CDP 端口。每个目标应用独占一个端口，不与其他应用或浏览器混用。目标应用的 shell 页面 URL 使用自定义 scheme（ChatGPT.app 为 `app://`，另有 `codex-sandbox://`）。

**加固（Hardening）**：目标应用对抗注入的手段。ChatGPT.app 已确认开启 `ElectronAsarIntegrity`（asar 完整性校验，阻断 asar 重打包路线）与 hardened runtime 签名；是否拦截调试参数需实测。

**宿主（Host）**：运行本工具的 macOS 机器，持有目标应用进程与 CDP 连接。

**远程端（Remote Client）**：在浏览器中访问宿主、查看并操作目标应用界面的单页客户端。

**中转（Relay）**：宿主内向远程端转发目标应用画面与反向输入的服务。默认只绑定本机回环地址。

**DOM 重绘模式（DOM Replay Mode）**：常态远程模式。采集目标页面 DOM 快照与增量，在远程端重建页面。原生菜单、系统对话框与 canvas 内容是其盲区。

**画面流模式（Screencast Mode）**：兜底远程模式。将目标窗口画面帧序列推送给远程端。

**启动器（Launcher）**：本工具内负责目标应用检测、带参启动与生命周期管理的模块。
_避免使用_：MacLauncher（那是独立的启动器产品，本工具通过其 SDK 接入它）

**检查器（Inspector）**：验证目标应用可注入性与连接健康状况的模块。

**前提校验（Preflight Check）**：确认目标应用是 Electron 且未加固拦截调试参数的检查。校验不通过则 CDP 路线整体失效。

**可信输入（Trusted Input）**：经 CDP Input 域下发、被页面视为真实用户操作的输入事件。页面内合成的脚本事件会被目标应用拒收，不属于可信输入。
