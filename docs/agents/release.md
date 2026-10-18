# 标准发布流程

所有者要求发正式版时，运行 `scripts/release.sh`。脚本完成版本进位、提交、推送与打 tag；tag 触发 [release.yml](../../.github/workflows/release.yml) 正式发布管线。无 tag 不发正式版。

## 用法

```sh
scripts/release.sh --dry-run   # 先空跑：打印版本计算与将执行的步骤
scripts/release.sh             # 确认无误后真实执行
```

前置条件由脚本强制检查，任一不满足即中止并说明原因：当前分支是 `main`、工作树干净、本地 `main` 与 `origin/main` 一致。

## 脚本行为

1. 从 `pubspec.yaml` 读取 `version`（版本唯一来源，单包仓库根目录）。
2. patch 加 1；达到 10 时 patch 归零、minor 加 1，例如 `1.0.6 → 1.0.7`、`1.0.9 → 1.1.0`。新版本统一使用三段式 `X.Y.Z`；历史 `+N` 后缀只用于读取当前版本，不延续到新版本，例如 `1.0.0+1 → 1.0.1`。
3. 写回 pubspec，提交（仅此文件），推送 `main`。
4. 打附注 tag `vX.Y.Z` 并推送。tag 去掉 `v` 后必须与写回的 pubspec version **精确一致**，否则 release.yml 的 validate-tag 步骤失败。

每步失败即停；脚本中止时错误消息内含恢复命令，先读消息再动手。

## 失败后恢复

| 失败点 | 状态 | 恢复 |
| --- | --- | --- |
| 前置检查 | 无任何改动 | 按提示解决（切 main / 提交改动 / 同步远端）后重跑 |
| push main | 版本提交仅在本地，本地领先远端 | `git push origin main`，然后手工 `git tag -a vX.Y.Z <commit>` 与 `git push origin vX.Y.Z`；直接重跑会被同步检查拦下 |
| push tag | main 已推送，tag 仅在本地 | `git push origin vX.Y.Z`（重跑脚本会被「部分失败」检查拦下并给出同一命令） |

`vX.Y.Z` 以脚本中止前打印的「发布 tag」为准。

版本规则与 dry-run 无副作用检查：`python3 scripts/test_release.py`。测试使用临时本地 Git 仓库和本地裸仓库，不访问 GitHub。

## 发版后验证

用本次发布的实际 tag 替换 `vX.Y.Z`：

```sh
gh run list -R Ghost233/GhostCodexInspect --workflow release.yml --branch vX.Y.Z --json databaseId,headBranch,headSha,status,conclusion,url
gh release view vX.Y.Z -R Ghost233/GhostCodexInspect --json tagName,isDraft,isPrerelease,assets,url
```

gh 网络抖动时重试几次再下结论。发布完成须同时满足：

- 本次 tag 对应的 `release.yml` 已结束，`status` 为 `completed`、`conclusion` 为 `success`，`headSha` 与发布 tag 指向的提交一致。
- GitHub Release 已正式发布，`isDraft` 和 `isPrerelease` 均为 `false`。`tagName` 去掉 `v` 后，与发布提交中 `pubspec.yaml` 的 version 一致。
- 远端资产包含 `Ghost-Codex-Inspect-X.Y.Z.dmg` 和 `SHA256SUMS.txt`，两者的 `size` 均大于 0。
- 当前工作区干净，本地 `main` 与远端 `main` 的完整提交 hash 一致。本地与远端发布 tag 均指向本次发布提交。

默认以这些远端发布结果和 Git 同步状态验收。下载发布资产到本地、追加本地哈希校验、安装或运行，仅在用户另行明确要求时执行。发布前的本地门禁为 `scripts/check-flutter.sh`（format / analyze / flutter test / node 测试）。

changelog 当前手工编写，Release notes 由管线生成固定文案。

## 与 MacLauncher 的关系

本流程与脚本自 Ghost233/MacLauncher（Ghost Launcher）的发布体系适配（单包根 pubspec、Flutter 3.47.7、应用名 Ghost Codex Inspect），行为差异仅仓库布局与命名；排障语义一致。
