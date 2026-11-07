#!/bin/bash
# Mac mini noda 定时任务安装器（launchd 版，2026-11-05 自 crontab 迁出）。
# 幂等：重复执行 = 刷新副本并重载。源 plist 即本目录 com.noda.*.plist（版本库管理），
# 安装位 ~/Library/LaunchAgents/。cron 退役存档见 crontab-retired-2026-11-05.txt。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

shopt -s nullglob
plist_files=("$SRC"/com.noda.*.plist)
if [ ${#plist_files[@]} -eq 0 ]; then
  echo "错误：$SRC 下没有 com.noda.*.plist" >&2
  exit 1
fi

for f in "${plist_files[@]}"; do
  name="$(basename "$f")"
  label="${name%.plist}"
  cp "$f" "$DEST/$name"
  # 先卸旧再装新（bootstrap 对已加载 label 会报错）
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$DEST/$name"
  echo "已安装 $label"
done

echo "全部完成。查看状态：launchctl print gui/$UID_N/com.noda.gate-probe"
