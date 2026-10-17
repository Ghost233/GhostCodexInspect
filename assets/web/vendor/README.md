# vendor：远程端离线依赖

本目录存放远程端单页（`assets/web/`）的离线 vendor 资产。远程端无框架、无构建链（见 ADR 0001），依赖以官方 ESM 构建直接离线伺服。

## rrweb-replay.js

- **包**：`@rrweb/replay`（rrweb 远端重建库，导出 `Replayer` 类；**不是** rrweb-player）
- **版本**：2.1.1
- **来源 URL**：`https://cdn.rrweb.com/replay/2.1.1/dist/replay.js`（经 `https://cdn.rrweb.com/replay/current/dist/replay.js` 302 跳转确认 current = 2.1.1）
- **取用日期**：2026-10-17
- **构建形式**：官方单文件 ESM 构建，`export { Replayer }`，浏览器直接 `import { Replayer } from './vendor/rrweb-replay.js'` 可用。
- **用途**：DOM 重绘模式下用 `Replayer` 的 `liveMode: true` + `startLive()` 在 sandboxed iframe 中重建目标应用 DOM，逐条 `addEvent()` 接收增量事件（方案见 docs/research/dom-replay.md §2、§3.1）。

## 更新方式

更新时重新下载对应版本 URL 覆盖本文件，并同步更新上面的版本号与来源 URL：

```sh
curl -sL https://cdn.rrweb.com/replay/<版本>/dist/replay.js -o assets/web/vendor/rrweb-replay.js
```
