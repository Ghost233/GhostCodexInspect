#!/bin/zsh
# 一键以调试模式重启 ChatGPT.app（Codex）——工单 #4/#6 的「唯一一次带参启动」。
#
# 手法即路线 A：完全退出实例后以 --remote-debugging-port=9238 拉起
# （open -a 对已运行实例会丢弃参数，Electron 单实例锁，所以必须先退干净）。
# 重启后 attach 不需要再重启：dart run tool/real_machine_probe.dart 可反复跑。
#
# 注意：会中断当前 codex 云端会话窗口；不会触碰 codex CLI。
#
# 用法：
#   终端：  tool/restart_target_debug.sh           （交互确认）
#   桌面：  双击「调试重启 ChatGPT（9238）.app」   （弹窗确认，内部调本脚本 --yes）
set -u

PORT=9238
APP_PATH="/Applications/ChatGPT.app"
BUNDLE_ID="com.openai.codex"

if [[ "${1:-}" != "--yes" ]]; then
  echo "将以调试模式（--remote-debugging-port=$PORT）重启 ChatGPT（Codex）。"
  echo "注意：会中断当前 codex 云端会话窗口；不会触碰 codex CLI。"
  read "REPLY?继续？[y/N] "
  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    echo "已取消。"
    exit 1
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "未找到目标应用：$APP_PATH"
  exit 1
fi

echo "1/4 退出运行中的实例…"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null
for i in {1..24}; do
  pgrep -f "$APP_PATH/Contents/MacOS" >/dev/null 2>&1 || break
  sleep 0.5
done
if pgrep -f "$APP_PATH/Contents/MacOS" >/dev/null 2>&1; then
  echo "  优雅退出超时（12s），强制结束…"
  pkill -f "$APP_PATH/Contents/MacOS" 2>/dev/null
  sleep 1
fi
if pgrep -f "$APP_PATH/Contents/MacOS" >/dev/null 2>&1; then
  echo "实例未能退出，中止（避免 open -a 对已运行实例丢弃参数）。"
  exit 1
fi

echo "2/4 带参启动（--remote-debugging-port=$PORT）…"
/usr/bin/open -a "$APP_PATH" --args --remote-debugging-port=$PORT

echo "3/4 等待调试端口就绪…"
READY=0
for i in {1..40}; do
  if curl -s "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.5
done

if [[ "$READY" != "1" ]]; then
  echo "4/4 失败：调试端口 20s 内未就绪。"
  echo "可能原因：加固拦截了 --remote-debugging-port（对照 #4 的拦截特征）。"
  echo "请把本输出贴给 GhostCodexInspect 会话。"
  exit 1
fi

echo "4/4 就绪：http://127.0.0.1:$PORT"
echo
echo "现在回到 GhostCodexInspect 会话告诉我「已重启」即可；"
echo "或自行实测：cd $HOME/Ghost233Code/GhostCodexInspect && \\"
echo "  $HOME/flutter/bin/dart run tool/real_machine_probe.dart"
