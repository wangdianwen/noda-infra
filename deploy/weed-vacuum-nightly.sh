#!/bin/sh
# weed 定时 vacuum（2026-10-07）：#680 实证大发布后垃圾比例越过 0.6 阈值即自动
# vacuum，与发布/其他负载并行时把单盘打到 util 96%/iowait 89%。治法=master 阈值
# 调 0.99（自动触发事实关闭）+ 每晚 02:00 定时手动 vacuum（守卫保护）。
# 守卫三重：tmp-s3-relay 存在=发布中跳过；load≥4 跳过；MemAvailable<500MB 跳过。
# compactionMBps=20（compose 落盘）继续兜底限速。
LOG=/var/log/noda-weed-vacuum.log
TS=$(date "+%F %T")
tg() { /mnt/mmc1-4/System/Scripts/telegram-alert.sh "$*" >/dev/null 2>&1; }
log() { echo "$TS $*" >> "$LOG"; }

if docker ps --format "{{.Names}}" | grep -q "^tmp-s3-relay-"; then
  log "SKIP: 发布中继容器在（发布进行中）"
  exit 0
fi
load=$(awk "{print int(\$1)}" /proc/loadavg)
if [ "$load" -ge 4 ]; then
  log "SKIP: load=$load >= 4"
  exit 0
fi
avail=$(grep MemAvailable /proc/meminfo | awk "{print \$2}")
if [ "$avail" -lt 512000 ]; then
  log "SKIP: avail=${avail}kB < 500MB"
  exit 0
fi

before=$(docker exec seaweedfs sh -c "echo volume.list | weed shell 2>/dev/null" | grep -oE "deleted:[0-9]+" | cut -d: -f2 | awk "{s+=\$1} END {print s+0}")
start=$(date +%s)
out=$(docker exec seaweedfs sh -c "echo vacuum | weed shell 2>&1" | tail -2)
rc=$?
elapsed=$(( $(date +%s) - start ))
after=$(docker exec seaweedfs sh -c "echo volume.list | weed shell 2>/dev/null" | grep -oE "deleted:[0-9]+" | cut -d: -f2 | awk "{s+=\$1} END {print s+0}")
if [ "$rc" = "0" ]; then
  log "OK: vacuum 完成 ${elapsed}s，垃圾 needle ${before} -> ${after}；out=$out"
  tg "weed 夜间 vacuum 完成：${elapsed}s，垃圾 needle ${before}→${after}（凌晨窗口，已确认无发布）"
else
  log "FAIL: rc=$rc out=$out"
  tg "weed 夜间 vacuum 失败 rc=$rc，请查 /var/log/noda-weed-vacuum.log"
fi
