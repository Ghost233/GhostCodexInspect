# 调试端口分配：真机 9238，fixture 9240，启动前占用预检

2026-10-17 事故：fixture 工具与真机共用 9238，真机占端口时 fixture 绑定静默失败，`connectCdp(9238)` 错连真机，往真机页面注入了采集器。决定：真机固定 9238（OpenCLI 惯例，避开浏览器默认 9222），开发期 fixture 固定 9240；所有 fixture 工具启动前执行 `isDebugPortAlive` 预检，占用即拒绝启动；带参启动前必须完全退出目标实例。

## Consequences

- 端口是「目标身份」的一部分：连上端口不等于连上期望的目标，target 枚举 + `isShellTarget`/`isPrimaryShellTarget` 校验是必经路径。
- 新增 fixture 工具一律 9240 + 预检，不得复用 9238。
