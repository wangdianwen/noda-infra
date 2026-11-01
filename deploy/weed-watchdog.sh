#!/bin/sh
# weed S3 假死守卫 v2（2026-11-01 #1159 发布 502 事故根治）
# v1 判例（2026-10-04 #571）：26k 对象 PUT 风暴冻死 weed，restart 自愈。
# v1 盲区（2026-11-01 判例，502 持续 20+ 分钟）：
#   ① 容器整体 Exited 时 docker exec 报 "is not running"，不匹配 v1 fail
#      模式 → 被当「活着」→ 计数清零 → 永不自愈；
#   ② docker restart 的 start 阶段失败时输出被 >/dev/null 吞掉，且动作后
#      不验证恢复结果，失败后无人再拉，站点 502 无人知晓。
# v2 行为：
#   - fail 模式新增容器未运行/不存在/cannot exec；任何匹配都计数
#   - 容器未运行 → 立即 docker start（免 restart 的 10s stop 宽限与 shim 风险）
#   - 运行中但 S3 探测连败 x2（10 分钟）→ docker restart（vacuum 卡死/假死场景）
#   - 动作输出全量落日志；动作后验证 100s：恢复→TG 通报；running 但 S3 未响应
#     → 视为卷加载预热，TG 通报等下轮复查；仍未 running → 二次 start，再失败
#     → TG【严重】人工介入
# 安装位置：r4s:/mnt/mmc1-4/System/Scripts/weed-watchdog.sh（存档 deploy/weed-watchdog.sh）
STATE=/tmp/weed-watchdog.count
TS() { date '+%F %T'; }
tg() { /mnt/mmc1-4/System/Scripts/telegram-alert.sh "$*" >/dev/null 2>&1; }

# fail 模式：连接类失败 + v1 盲区（容器未运行/不存在）。
# 403/404 等应用层响应说明 S3 活着，不算 fail（busybox wget 对 4xx/5xx
# 的报错形如 "server returned error"，不含下列关键词）。
FAIL_PAT="can't connect|timed out|[Cc]onnection refused|unreachable|no route to host|is not running|No such container|cannot exec|exec failed|is paused"

probe() { docker exec seaweedfs wget -q -T 5 -O /dev/null http://127.0.0.1:8333/ 2>&1; }

if ! docker inspect seaweedfs >/dev/null 2>&1; then
  echo "$(TS) FAIL: seaweedfs 容器不存在（被删除？）不自动重建，人工介入"
  tg "weed 守卫【严重】：seaweedfs 容器不存在（可能被删除），站点 502 中，请立即人工介入！"
  exit 1
fi

probe_err=$(probe)
if ! echo "$probe_err" | grep -qE "$FAIL_PAT"; then
  rm -f "$STATE"   # 活着（含应用层 4xx/5xx），清零
  exit 0
fi

n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STATE"
echo "$(TS) S3 probe FAIL #$n: $probe_err"

state=$(docker inspect -f "{{.State.Status}}" seaweedfs 2>/dev/null)
if [ "$state" = "running" ]; then
  # 运行中假死：保持 v1 的 x2 防抖（IO 饥饿/慢响应常可自愈，restart 反伤发布）
  if [ "$n" -lt 2 ]; then exit 0; fi
  echo "$(TS) action: docker restart seaweedfs (S3 dead x$n)"
  out=$(docker restart -t 10 seaweedfs 2>&1)
  rc=$?
  echo "$(TS) restart rc=$rc out=${out:-<empty>}"
else
  # 容器没在跑（含 restart 失败留下的 Exited）：立即 start，不等 10 分钟
  echo "$(TS) action: docker start seaweedfs (state=$state)"
  out=$(docker start seaweedfs 2>&1)
  rc=$?
  echo "$(TS) start rc=$rc out=${out:-<empty>}"
fi
rm -f "$STATE"

# 动作后验证：最多 100s。分三档结局：recovered / warming / still-down
i=0; verdict=""
while [ $i -lt 10 ]; do
  sleep 10; i=$((i+1))
  st=$(docker inspect -f "{{.State.Status}}" seaweedfs 2>/dev/null)
  [ "$st" = "running" ] || continue
  pe=$(probe)
  if ! echo "$pe" | grep -qE "$FAIL_PAT"; then verdict=recovered; break; fi
  verdict=warming   # running 但 S3 未响应：卷加载预热中
done

case "$verdict" in
  recovered)
    echo "$(TS) recovered after ~${i}0s"
    tg "weed 守卫：S3 故障（x$n 轮），已自动拉起并验证恢复（~${i}0s）。"
    ;;
  warming)
    echo "$(TS) running but S3 not responding after ~${i}0s（卷加载预热中），下轮复查"
    tg "weed 守卫：已拉起 seaweedfs（running），S3 ${i}0s 未响应=卷预热中，约 1-2 分钟恢复；下轮探测复查。"
    ;;
  *)
    echo "$(TS) still not running after action+100s，二次 docker start"
    docker start seaweedfs >/dev/null 2>&1
    sleep 8
    st=$(docker inspect -f "{{.State.Status}}" seaweedfs 2>/dev/null)
    if [ "$st" = "running" ]; then
      echo "$(TS) second start: running（预热中），下轮复查"
      tg "weed 守卫：首次拉起 100s 未恢复，二次 docker start 已拉起（running，预热中）；下轮复查，再失败请人工介入。"
    else
      echo "$(TS) second start FAILED: status=${st:-inspect-fail} —— 人工介入"
      tg "weed 守卫【严重】：start/restart 与二次拉起均失败（status=${st:-inspect失败}），站点 502 中，请立即人工介入！"
      exit 1
    fi
    ;;
esac
