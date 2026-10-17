# Electron 替身 fixture

GhostCodexInspect 开发期使用的最小 Electron 替身（hello-world）。它用于在不触碰真实目标应用（ChatGPT.app）的前提下，验证「目标检测 → 前提校验 → 带参启动 → CDP attach → target 枚举 → Runtime.evaluate」全链路。

## 一次性安装

```sh
cd tool/fixture
npm install electron   # 首次需下载约 100MB，属正常
```

`node_modules/` 被本目录 `.gitignore` 忽略，仅存在于开发机上。

> 注意：若开发机 shell 导出了 `ELECTRON_RUN_AS_NODE=1`（常见于其他 Electron
> 项目的配置），Electron 二进制会退化为 Node 运行，fixture 起不来。
> 启动器在直接执行模式下会显式置空该变量；手动 `npm run debug` 前请先
> `unset ELECTRON_RUN_AS_NODE`。

## 用法

手动验证（可选）：

```sh
npm run debug   # 等价于 electron . --remote-debugging-port=9238
```

随后访问 <http://127.0.0.1:9238/json/list> 应能看到 `file://` 开头的 page target。

自动化全链路验证（推荐，无需手动启动）：

```sh
cd <仓库根目录>
/Users/ghost233/flutter/bin/dart run tool/verify_fixture_chain.dart
```

该脚本会：以 `node_modules/electron/dist/Electron.app` 作为「标准 Electron 目标应用」执行检测与前提校验（走通用判据），用本目录作为应用参数带调试端口启动 fixture，attach CDP、枚举 target、过滤 shell 页面（fixture 的 shell URL 为 `file://` scheme），执行 `Runtime.evaluate` 读回 `document.title`，最后完整停止 fixture 进程。
