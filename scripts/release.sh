#!/usr/bin/env bash
# release.sh — GhostCodexInspect 标准发版（自 MacLauncher scripts/release.sh 适配）
#
# 流程：读 pubspec.yaml 版本 → patch +1，满 10 向 minor 进位 →
# 写回三段版本并提交（仅 pubspec.yaml）→ push origin main → 打 vX.Y.Z tag → push tag。
# tag 触发 .github/workflows/release.yml，该管线要求 tag 去掉 v 前缀后与
# pubspec version 精确一致；历史 +N 后缀不延续到新版本。
#
# 用法：
#   scripts/release.sh            真实执行（必须在 main、工作树干净、与 origin/main 同步）
#   scripts/release.sh --dry-run  只打印将执行的步骤，不改动任何内容
#
# 每步失败即停（set -euo pipefail）；push/tag 失败会明确报错，不静默。
# 部分失败的恢复步骤见 docs/agents/release.md。

set -euo pipefail

PUBSPEC="pubspec.yaml"
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
Usage: scripts/release.sh [--dry-run]
  --dry-run   打印将执行的步骤与版本计算结果，不修改文件、不提交、不推送
EOF
}

die() {
  echo "release: 错误: $*" >&2
  exit 1
}

info() {
  echo "release: $*"
}

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    echo "  \$ $*"
    "$@"
  fi
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $arg" ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "不在 git 仓库内"
cd "$REPO_ROOT"
[ -f "$PUBSPEC" ] || die "未找到 ${PUBSPEC}（请确认仓库布局）"

# ---- 前置检查（dry-run 同样执行，全部为只读校验） ----

branch="$(git symbolic-ref --short HEAD 2>/dev/null)" || die "HEAD 处于分离状态"
[ "$branch" = "main" ] || die "必须在 main 分支执行（当前: ${branch}）"

[ -z "$(git status --porcelain)" ] || die "工作树不干净，请先提交或暂存改动"

info "拉取 origin/main 以确认同步状态…"
git fetch origin main --quiet
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git rev-parse origin/main)"
[ "$local_sha" = "$remote_sha" ] || die "本地 main 与 origin/main 不一致（本地 ${local_sha}，远端 ${remote_sha}），先同步再发版"

# ---- 版本计算 ----

current="$(awk '/^version:/{print $2; exit}' "$PUBSPEC")"
[ -n "$current" ] || die "无法从 $PUBSPEC 读取 version 字段"

semver="${current%%+*}"

core_major="${semver%%.*}"
rest="${semver#*.}"
core_minor="${rest%%.*}"
core_patch="${rest#*.}"
case "$core_major$core_minor$core_patch" in
  *[!0-9]*|*..*|"") die "版本号 '$current' 不是 x.y.z(+N) 格式" ;;
esac
[ "$semver" = "$core_major.$core_minor.$core_patch" ] || die "版本号 '$current' 不是 x.y.z(+N) 格式"

new_patch=$((core_patch + 1))
if [ "$new_patch" -ge 10 ]; then
  core_minor=$((core_minor + 1))
  new_patch=0
fi
new_version="$core_major.$core_minor.$new_patch"
tag="v$new_version"

info "当前版本: $current"
info "下一版本: $new_version"
info "发布 tag: $tag"

# ---- 幂等与部分失败保护 ----
# - 当前版本的 tag 已在本地创建但远端没有 → 上次死在「推 tag」，直接补推即可。
# - 目标 tag 在本地或远端已存在 → 冲突，中止。

current_tag="v$current"
if git rev-parse -q --verify "refs/tags/$current_tag" >/dev/null \
  && [ -z "$(git ls-remote --tags origin "refs/tags/$current_tag")" ]; then
  die "检测到上次部分失败：tag ${current_tag} 已在本地创建但未推送。恢复：git push origin ${current_tag}"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "tag ${tag} 已存在于本地；若属上次部分失败，请按 docs/agents/release.md 恢复"
fi
if [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
  die "tag ${tag} 已存在于远端，版本 ${new_version} 已发布过，无需重复执行"
fi

# ---- 执行 ----

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF
将执行的步骤：
  1. 写回版本：${PUBSPEC} 中 version: ${current} → version: ${new_version}
  2. 提交：git commit（仅 ${PUBSPEC}），信息 "chore(release): ${tag}"
  3. 推送主干：git push origin main
  4. 打 tag：git tag -a ${tag}
  5. 推 tag：git push origin ${tag}（触发 release.yml 正式发布管线）
EOF
  exit 0
fi

awk -v new="$new_version" '
  !done && /^version:/ { sub(/version:.*/, "version: " new); done=1 }
  { print }
' "$PUBSPEC" > "$PUBSPEC.tmp"
mv "$PUBSPEC.tmp" "$PUBSPEC"
info "已写回 $PUBSPEC: version: $new_version"

run git add "$PUBSPEC"
run git commit -m "chore(release): $tag"

info "推送 main…"
git push origin main || die "push main 失败：版本提交仅在本地，可直接重试 git push origin main，勿重复运行本脚本（会再次进位版本）"

run git tag -a "$tag" -m "GhostCodexInspect $tag"

info "推送 tag ${tag}…"
git push origin "$tag" || die "push tag 失败：main 已推送但 tag 未发出。恢复：git push origin ${tag}（tag 已在本地创建）"

info "完成：$tag 已推送，release.yml 将由 tag 触发。"
info "跟踪：gh run list -R Ghost233/GhostCodexInspect --workflow release.yml"
