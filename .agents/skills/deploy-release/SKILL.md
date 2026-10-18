---
name: deploy-release
description: 发布 GhostCodexInspect 正式版（版本进位、推送、打 tag、触发 release.yml 出 DMG）。适用于用户要求发版、发布新版本、打 release tag 或 deploy release 时。仅在用户明确要求发正式版时使用。
---

# deploy-release

发布 GhostCodexInspect 正式版。唯一执行入口是仓库脚本 `scripts/release.sh`；脚本行为、失败恢复与发布完成条件以[发布文档](../../../docs/agents/release.md)为准，本 skill 不复述其实现。

## 步骤

1. 确认当前工作区是 GhostCodexInspect 仓库，且用户明确要求发正式版。两者都成立才继续，否则停止并说明。
2. 发布前门禁：`scripts/check-flutter.sh`（format / analyze / flutter test / node 测试）全绿；未过时先修复，不要把红灯带进发布。
3. 空跑 `scripts/release.sh --dry-run`，向用户展示将发布的版本号与 tag。dry-run 输出无异常即继续下一步。
4. 执行 `scripts/release.sh`。完成标准：脚本输出「完成：vX.Y.Z 已推送」。脚本中途失败时，按错误消息与 `docs/agents/release.md` 的恢复表执行对应的 git 命令；恢复路径以该文档为准。
5. 按发布文档的"发版后验证"检查本次 tag/提交对应的管线、正式 Release、远端资产和本地 Git 同步状态，全部满足完成条件后结束。发布资产的本地下载、哈希校验、安装或运行，仅在用户另行明确要求时执行。
