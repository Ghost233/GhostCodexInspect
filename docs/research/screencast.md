# 纯 CDP 画面流实测报告（#6）

实测时间：2026-10-17 22:07（探针原始数据：`docs/research/real-probe-20261017-220759.md`）。
目标：ChatGPT.app 26.1013.31256，主 shell `app://-/index.html`，视口 1280×1024 dpr 1。

## `Page.startScreencast` vs `Page.captureScreenshot`——**startScreencast 主推，截图轮询备选**

### startScreencast 实测（JPEG，everyNthFrame=1，ack 流控）

| 档位 | 实测帧率 | 带宽 | 平均帧字节 |
|---|---|---|---|
| q60，5s | 40.0 fps | **12.5 MB/s** | 319 KB |
| q40，2s | 62.5 fps | 20.7 MB/s | 340 KB |
| q80，2s | 47.5 fps | 10.0 MB/s | 215 KB |

读法：源端推帧随画面变化率波动（实测时 UI 有持续动效，帧率 40-62fps），质量档
对单帧大小有影响但帧率主导总带宽；三档单帧均在 200-350KB。**结论：必须限帧**——
`everyNthFrame=4` 把推帧压到 ~10-15fps，q60 下带宽约 2-4 MB/s，LAN（≥1Gbps）
轻松承载，Wi-Fi LAN 也可接受。无限帧直连只适合本机。

### captureScreenshot 轮询备选

单帧延迟 44ms、约 50KB（q60）。理论上限 ~15fps（受 44ms 串行往返约束），带宽
~750KB/s，比 screencast 限帧后更省，但没有推送式流控、轮询节奏需自管理。
**定位：screencast 被未来版本改动/移除时的备选**，一期不上。

### 帧格式与传输决策

- 编码：JPEG（实测档位可控、单帧 200-350KB）；PNG 未测（无损对聊天 UI 文本
  更锐利但体积数倍，一期不上）。
- 线上格式：一期保持 base64 文本帧（#12 已交付，信封 `{v,ch,t,seq,ts,data}` 全 JSON）；
  **二期升级二进制帧**：按 q60 限帧后 ~3MB/s 估算，base64 多耗 33% 带宽且 JSON
  编解码 CPU 可观，二进制帧（首字节通道号 + seq 头 + 裸 JPEG 载荷）是明确的
  二期优化项，已记入后续工单。
- 帧与输入同步：ack 流控天然背压（#12 已交付）；输入事件走独立信封不排队在
  帧流后，延迟可接受。

## DOM 模式侧带出的数据（rrweb 干跑 3s，供带宽模型共享）

- 全量快照 **2.86MB**（单事件，54 个样式表 CSSOM 内联 + 字体内嵌所致），
  增量 3s 仅 ~17KB（24 事件含 1 全量）。
- 含义：首屏/resync 发 2.86MB JSON 文本帧偏重但一次性；**fflate 压缩值得上**
  （#11 留的债），gzip 对 JSON+CSS 文本压缩率预期 5-10×。已记入后续工单。
- 增量稳态带宽 KB 级/秒，DOM 模式常态带宽优势 confirmed。

## canvas 截帧

主 shell `canvasCount=0`（聊天 UI 无 canvas）。recordCanvas webp ≤15fps 的预算
问题在真机上暂无对象，维持 #3 原设计（有 canvas 时截帧嵌入），不展开。

## 文件对话框拦截

`Page.setInterceptFileChooserDialog` 未实测（真机触发文件选择有交互副作用）。
一期架构上预留（#12 工单列为可选项），真机首次需要时再验。

## 结论汇总

| 项 | 决策 |
|---|---|
| 主推方案 | `Page.startScreencast` JPEG q60 + `everyNthFrame=4` 限帧（~10-15fps，2-4MB/s） |
| 备选 | `Page.captureScreenshot` 轮询（44ms/帧，~750KB/s），一期不上 |
| 线上格式 | 一期 base64 文本帧（已交付）；二期二进制帧 |
| DOM 模式优化 | fflate 压缩批量事件（首屏 2.86MB → 预期 300-600KB） |
| 多 shell | 画面流/DOM 采集目标=主 shell（`app://-/index.html` 无 initialRoute），见 #4 报告 |
