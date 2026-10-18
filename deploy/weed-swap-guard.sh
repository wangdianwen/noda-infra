#!/bin/sh
# weed swap 债守卫（2026-10-04 33s manifest GET 事故·第 3 层防线）
# 背景：weed 热内存曾被换出到与数据同盘（sda2）的 swapfile，发版风暴期
# 换页致 manifest GET 33s。本机 docker 不支持 swap limit（docker update
# --memory-swap 报 kernel does not support），禁 swap 只能 cgroup 直写，
# 且容器 recreate 会重置——本守卫每 10 分钟核对并自愈 + Telegram 告警。
cid=$(docker inspect -f "{{.Id}}" seaweedfs 2>/dev/null) || exit 0
[ -n "$cid" ] || exit 0
m="/sys/fs/cgroup/docker/$cid/memory.swap.max"
cur=$(cat "$m" 2>/dev/null) || exit 0
[ "$cur" = "0" ] && exit 0
echo 0 > "$m" 2>/dev/null || exit 0
echo "$(date "+%F %T") drift: memory.swap.max=$cur -> 0 (recreate/带外启动)"
/mnt/mmc1-4/System/Scripts/telegram-alert.sh \
  "weed swap 守卫：seaweedfs cgroup memory.swap.max 漂移为 $cur（容器 recreate 或带外启动），已自动重设 0。刚发版属预期可忽略；频繁出现请查 compose。" \
  >/dev/null 2>&1
