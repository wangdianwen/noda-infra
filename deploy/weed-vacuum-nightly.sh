#!/bin/sh
# weed 夜间维护（2026-10-07）：①删各产品 -old 前缀（蓝绿发布切换后的旧版，释放
# 空间）②vacuum 回收垃圾 needle。守卫：发布中继容器存在 / load≥4 / avail<500MB
# 任一命中跳过；删 -old 前额外守卫=对应主前缀哨兵可访问（防误删唯一版本）。
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

# ① 蓝绿旧版清理：每个 -old 前缀，主前缀健康（哨兵可列）才删
for old in $(docker exec seaweedfs sh -c "echo \"fs.ls /buckets/noda-static/sites/\" | weed shell 2>/dev/null" | grep -oE "[a-z-]+-old" | sort -u); do
  prod=${old%-old}
  sentinel=$(docker exec seaweedfs sh -c "echo \"fs.ls /buckets/noda-static/sites/$prod/\" | weed shell 2>/dev/null" | head -1)
  if [ -z "$sentinel" ]; then
    log "SKIP-old: $prod 主前缀异常（fs.ls 空），保留 $old"
    continue
  fi
  docker exec seaweedfs sh -c "echo \"fs.rm /buckets/noda-static/sites/$old\" | weed shell 2>&1" | grep -q "rm:" || { log "FAIL-old: fs.rm $old"; continue; }
  log "OK-old: 已删 $old（$prod 旧版）"
done

# ② vacuum 回收垃圾
before=$(docker exec seaweedfs sh -c "echo volume.list | weed shell 2>/dev/null" | grep -oE "deleted:[0-9]+" | cut -d: -f2 | awk "{s+=\$1} END {print s+0}")
start=$(date +%s)
out=$(docker exec seaweedfs sh -c "printf 'lock\nvolume.vacuum 0.3\n' | weed shell 2>&1" | tail -2)
rc=$?
elapsed=$(( $(date +%s) - start ))
after=$(docker exec seaweedfs sh -c "echo volume.list | weed shell 2>/dev/null" | grep -oE "deleted:[0-9]+" | cut -d: -f2 | awk "{s+=\$1} END {print s+0}")
if [ "$rc" = "0" ]; then
  log "OK-vacuum: ${elapsed}s，垃圾 needle ${before} -> ${after}；out=$out"
  tg "weed 夜间维护完成： vacuum ${elapsed}s，垃圾 ${before}→${after}"
else
  log "FAIL-vacuum: rc=$rc out=$out"
  tg "weed 夜间维护 vacuum 失败 rc=$rc，查 /var/log/noda-weed-vacuum.log"
fi
