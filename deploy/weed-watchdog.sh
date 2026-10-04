#!/bin/sh
# weed S3 假死守卫（2026-10-04 #571 事故·第 4 层防线）
# 背景：26k 对象 PUT 风暴触发 vacuum，vacuum 卡死把 weed 单进程全咬住
# （master/filer/S3 全停、线上 502、docker healthcheck 报 unhealthy 但无人
# 响应）。现有 healthcheck 只探 master :9333/cluster/status——本守卫每
# 5 分钟直探 S3 :8333，连续 2 轮「连不上/超时」（403/404 等应用层响应
# 算活着）自动 docker restart seaweedfs + Telegram 告警。
# 安装位置：r4s:/mnt/mmc1-4/System/Scripts/weed-watchdog.sh（与 weed-swap-guard.sh 同目录）
STATE=/tmp/weed-watchdog.count
probe_err=$(docker exec seaweedfs wget -q -T 5 -O /dev/null http://127.0.0.1:8333/ 2>&1)
if echo "$probe_err" | grep -qE "can't connect|timed out|[Cc]onnection refused|unreachable|no route to host"; then
  n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$STATE"
  echo "$(date '+%F %T') S3 probe FAIL #$n: $probe_err"
  if [ "$n" -ge 2 ]; then
    echo "$(date '+%F %T') restarting seaweedfs (S3 dead x$n)"
    docker restart seaweedfs >/dev/null 2>&1
    rm -f "$STATE"
    /mnt/mmc1-4/System/Scripts/telegram-alert.sh \
      "weed 守卫：S3 端口连续 $n 轮连接失败（vacuum 卡死/假死），已自动 docker restart seaweedfs。约 1-2 分钟恢复；未恢复请人工介入。" \
      >/dev/null 2>&1
  fi
  exit 0
fi
# 应用层有响应（含 403/404）= 活着，清零计数
rm -f "$STATE"
