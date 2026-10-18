# DOM 重绘模式使用 rrweb 采集与重建，放弃自研 MutationObserver 管线

DOM 重绘模式需要采集目标页面 DOM 变化并在远程端重建。#3 调研结论：自研 MutationObserver 序列化等于重写 rrweb 最难的部分（增量序列化、节点 id 映射、样式表处理）；CDP DOM 域的 `documentUpdated` 会使 node id 全失效，不能直接当增量源。决定性优势：rrweb 序列化样式表时走 CSSOM 内联，`app://` 协议的样式随快照走，不依赖远程端访问 `app://` 资源。决定：采集端 vendor `@rrweb/record`（经典脚本注入），重建端 vendor `@rrweb/replay`（Replayer liveMode），协议层自研薄信封。

## Consequences

- 升级 rrweb 版本时需重新套用本地补丁（`customElements.define` 对非法自定义元素名如 `<webview>` 的 try/catch，检索锚点「GhostCodexInspect 补丁」，见 assets/web/vendor/README.md）。
- 采集器注入脚本必须 IIFE 包裹（经典脚本顶层 let/const 会成为页面永久词法绑定，曾造成真机 `testableAccessors` 重复声明冲突）。
- canvas 内容走 rrweb recordCanvas（≤15fps webp），原生菜单/系统对话框是盲区，由画面流模式兜底。
