#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
flutter_command="${FLUTTER_BIN:-$(command -v flutter || echo "${HOME}/flutter/bin/flutter")}"
dart_command="${DART_BIN:-$(command -v dart || echo "${HOME}/flutter/bin/dart")}"

check_format() {
  # 检查模式（--output=none）不改文件；失败时给出修复命令。
  if ! "$dart_command" format --output=none --set-exit-if-changed lib test tool integration_test; then
    echo "格式检查未过（以上文件未格式化）。修复：dart format lib test tool integration_test" >&2
    return 1
  fi
}

check_analysis() {
  "$flutter_command" --suppress-analytics analyze --no-pub
}

check_tests() {
  "$flutter_command" --suppress-analytics test --no-pub
  # 远程端（assets/web）的 node 单测：有 node 就跑，没有不阻塞。
  if command -v node >/dev/null 2>&1; then
    (cd assets/web && node --test test/)
  fi
}

case "${1:-check}" in
  format) check_format ;;
  analyze) check_analysis ;;
  test) check_tests ;;
  check)
    check_format
    check_analysis
    check_tests
    ;;
  *)
    echo 'Usage: scripts/check-flutter.sh [check|format|analyze|test]' >&2
    exit 2
    ;;
esac
