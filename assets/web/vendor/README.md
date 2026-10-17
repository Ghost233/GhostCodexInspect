# vendor：远程端离线依赖

本目录存放远程端单页（`assets/web/`）的离线 vendor 资产。远程端无框架、无构建链（见 ADR 0001），依赖以官方 ESM 构建直接离线伺服。

## rrweb-replay.js

- **包**：`@rrweb/replay`（rrweb 远端重建库，导出 `Replayer` 类；**不是** rrweb-player）
- **版本**：2.1.1
- **来源 URL**：`https://cdn.rrweb.com/replay/2.1.1/dist/replay.js`（经 `https://cdn.rrweb.com/replay/current/dist/replay.js` 302 跳转确认 current = 2.1.1）
- **取用日期**：2026-10-17
- **构建形式**：官方单文件 ESM 构建，`export { Replayer }`，浏览器直接 `import { Replayer } from './vendor/rrweb-replay.js'` 可用。
- **用途**：DOM 重绘模式下用 `Replayer` 的 `liveMode: true` + `startLive()` 在 sandboxed iframe 中重建目标应用 DOM，逐条 `addEvent()` 接收增量事件（方案见 docs/research/dom-replay.md §2、§3.1）。

## rrweb-record.js

- **包**：`@rrweb/record`（rrweb 页面采集库，导出 `record` 函数）
- **版本**：2.1.1
- **来源 URL**：`https://cdn.rrweb.com/record/2.1.1/dist/record.js`
- **取用日期**：2026-10-17
- **构建形式**：官方单文件 **ESM** 构建（尾部 `export { record }`）。**不直接给浏览器 import**：由宿主（`lib/dom/dom_collector.dart`）读入源码、剥掉 export 行、拼接采集 glue 后，经 CDP `Page.addScriptToEvaluateOnNewDocument` / `Runtime.evaluate` 以经典脚本注入目标页面（目标页面不联网、不加载任何外部脚本）。
- **用途**：DOM 重绘模式的采集侧——全量快照 + MutationObserver 增量，事件经 CDP Runtime binding（`__gciEmit`）回传宿主（工单 #11）。

## fflate.js

- **包**：`fflate`（纯 JS 压缩库，导出 `unzlibSync`/`strFromU8` 等）
- **版本**：0.8.2
- **来源 URL**：`https://unpkg.com/fflate@0.8.2/esm/browser.js`（jsdelivr 同路径 SSL 握手失败，改 unpkg；内容为未压缩 ESM 源码，含 `export` 声明）
- **取用日期**：2026-10-17
- **构建形式**：官方 ESM 源码，浏览器直接 `import { unzlibSync, strFromU8 } from '../vendor/fflate.js'` 可用。
- **用途**：远程端解压宿主侧 zlib 压缩的信封 payload（`{"z":"fflate","b64":...}` 包装，见 lib/relay/envelope.dart 与 lib/relay/compression.dart；工单 #14）。

## 更新方式

更新时重新下载对应版本 URL 覆盖本文件，并同步更新上面的版本号与来源 URL：

```sh
curl -sL https://cdn.rrweb.com/replay/<版本>/dist/replay.js -o assets/web/vendor/rrweb-replay.js
curl -sL https://cdn.rrweb.com/record/<版本>/dist/record.js -o assets/web/vendor/rrweb-record.js
```
