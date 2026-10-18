# 单一 Flutter package 布局，不建 monorepo

宿主（Flutter）、远程端（纯静态 web）、fixture（Electron 替身）、工具脚本共存一仓。决定：单 package 根 pubspec，远程端在 `assets/web/`（无构建链），fixture 在 `tool/fixture/`（node_modules gitignore），验证工具在 `tool/`，集成测试在 `integration_test/`。

## Consequences

- `pubspec.yaml` 的 assets 目录声明**不递归子目录**，`assets/web/` 下的 css/js/vendor 必须逐个显式列出（打包缺文件曾实锤）。
- CI 检查（scripts/check-flutter.sh）= format + analyze + flutter test + node 测试，单链跑全仓。
