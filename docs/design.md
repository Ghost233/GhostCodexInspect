# GhostCodexInspect 界面设计

宿主应用（Flutter macOS）的页面职责与视觉实现记录。视觉基线遵循
macos-ui-standards skill 的 standard.md（Apple 文本角色、语义色、
macOS 布局默认值）。术语遵循根目录 GLOSSARY.md。

## 页面职责

单窗口四模块，侧栏导航（224pt，macOS 基线），侧栏底部常驻
MacLauncher 连接状态。

| 模块 | 职责 | 关键操作 |
| --- | --- | --- |
| 启动器 | 目标应用（ChatGPT.app）检测状态、前提校验结果、带参启动/停止/重启 | 真机操作一律弹确认对话框（不碰 codex CLI 的提示写进对话框） |
| 检查器 | CDP 连接健康、shell 页面枚举、注入脚本存活探测入口、加固检测结果 | 「CDP 探测」为只读勘察 |
| 中转台 | WS 服务状态、token 与带 token URL 一键复制、远程端列表、局域网开关、中继会话（DOM 重绘/画面流，一期互斥）启停 | 局域网开关带安全警示；运行中切换会重启中转并换令牌 |
| 远程视图 | 本机只读预览：内嵌 WebView 加载中转伺服地址（`ro=1`） | 输入只放远程端，预览不捕获键鼠 |

## 实现与角色映射

主题：`lib/ui/theme.dart` `buildAppTheme(Brightness)`，双套语义色
（浅/深调色板同 GhostModelDeck 家族）。

| Apple 角色 | Material 映射 | 参数 |
| --- | --- | --- |
| Title 1 | headlineSmall | 22 w400 |
| Title 2 | titleLarge | 17 w400（侧栏应用名） |
| Title 3 | titleMedium | 15 w600（卡片标题） |
| Headline | titleSmall | 13 w700 |
| Body | bodyMedium | 13/16 |
| Callout | bodySmall | 12（辅助说明，onSurfaceVariant） |
| Caption 1 | labelSmall | 10 |

等宽内容（路径、URL、token、PID）走 `MonoText`（Menlo）且可选中复制。

布局：页内边距 24；卡片圆角 12 padding 24（`SectionCard`）；按钮高 32、
圆角 8；分隔线 1pt；窗口最小 960×640（macos/Runner/MainFlutterWindow.swift）。

控件状态：操作按钮 busy 时禁用 + 就地 `BusyBar` 进度；失败就地
`ErrorBar`（可选取文本）；空态每页有引导文案；状态用 `StatusChip`/
`StatusDot`（neutral/success/warning/error 四档语义色）。

## 验收记录

- 2026-10-17 工单 #13 首次验收：浅色/深色截图见
  `docs/screenshots/#13/`（窗口 1280×800）。
  flutter analyze 零问题；flutter test 81 例全过。
