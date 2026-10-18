# 宿主中转后端内嵌于 Flutter 应用（Dart），CDP 走 puppeteer 主实现 + 裸 WebSocket 回退

中转后端需要与宿主同生命周期（随 app 启停、状态进 UI、注册为 MacLauncher 服务）。#5 决定：不引入独立后端进程/语言，直接在 Flutter 应用内用 Dart 实现——shelf 系做 HTTP/WS 服务，puppeteer 3.26.0（纯 Dart 的 CDP 客户端）做主实现，`web_socket_channel` 手写裸 CDP 客户端做回退（puppeteer 连接失败时降级，接口一致 `CdpClient`）。

## Consequences

- 单进程架构：中转、会话、UI 状态在同一事件循环，无 IPC。
- 远程端静态资源由宿主直接伺服（`RelayServer.resolveWebRoot()` 按 cwd 相对 → app 包内 flutter_assets 候选序解析）。
- macOS 沙盒要求显式声明 `network.server` + `network.client` 两个 entitlement，缺失时宿主内 CDP/WS 全部静默被拒。
