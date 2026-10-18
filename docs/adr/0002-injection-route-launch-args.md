# 注入路线 A：启动参数带 CDP 调试端口，排除 asar 重打包

目标应用 ChatGPT.app（Codex）需要接入远程访问。三条候选路线：A. `--remote-debugging-port=9238` 带参启动；B. 解包 app.asar 注入主进程后重打包；C. 源码集成（目标应用非自有，不可用）。#2 实测发现 Info.plist 含 `ElectronAsarIntegrity` 且签名为 hardened runtime，asar 重打包会破坏完整性校验与签名，路线 B 不可行。决定：只用路线 A——先完全退出实例，再带参启动，CDP 接管。

## Consequences

- 目标应用每次需要接管能力时必须带参启动；已运行实例不丢参数（`open -a` 对已运行实例丢弃参数），因此启动顺序是「退出 → 带参启动」。
- 目标应用自更新不影响注入能力（不改包）。
- 零代码签名破坏，可随时撤销（普通重启即回到未接管状态）。
