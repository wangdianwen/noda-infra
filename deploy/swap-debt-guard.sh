#!/bin/sh
# swap 债周清（2026-10-07：swapfile 1G 连续 99.9% 满——immich 栈 ~470MB 冷页+
# postgres+clash/hermes，Linux 不主动换回；swap 满时任何新换页需求=OOM/抖动，
# 实测拖慢 docker 建容器 191s（#661）与 weed 轮转 4-6 倍波动）。
# 动作：swapoff+swapon 强制冷页回内存/重新计量。安全阈值必须硬：
#   MemAvailable > SwapUsed + 512MB（swapoff 要把换出页读回 RAM）且 1 分钟负载 < 2
# 不满足则 TG 告警跳过（人肉窗口清或 docker restart immich_server 直接丢弃其
# ~470MB 匿名页）。周日 05:30 跑：避开 05:10 快照（同盘 IO）与 03:30 百度上传。
LOG=/var/log/noda-swap-guard.log
TS=$(date "+%F %T")
avail=$(grep MemAvailable /proc/meminfo | awk "{print \$2}")
sw_total=$(grep SwapTotal /proc/meminfo | awk "{print \$2}")
sw_free=$(grep SwapFree /proc/meminfo | awk "{print \$2}")
sw_used=$((sw_total - sw_free))
load=$(awk "{print int(\$1)}" /proc/loadavg)
need=$((sw_used + 512 * 1024))
log() { echo "$TS $*" >> "$LOG"; }
tg() { /mnt/mmc1-4/System/Scripts/telegram-alert.sh "$*" >/dev/null 2>&1; }
# swap 占用低于 10% 视为健康，不折腾
if [ "$sw_used" -lt $((sw_total / 10)) ]; then
  log "healthy: swap used ${sw_used}kB (<10%), skip"
  exit 0
fi
if [ "$avail" -lt "$need" ] || [ "$load" -ge 2 ]; then
  log "SKIP: avail=${avail}kB need=${need}kB load=$load"
  tg "swap 清债跳过：可用内存 ${avail}kB < 需要 ${need}kB（或负载 $load≥2）。swap 仍 ${sw_used}kB 满——建议空窗期 docker restart immich_server（释放 ~470MB 冷页）后自动满足。"
  exit 0
fi
if swapoff /mnt/mmc1-4/System/swapfile && swapon /mnt/mmc1-4/System/swapfile; then
  after=$(grep SwapFree /proc/meminfo | awk "{print \$2}")
  log "CLEARED: swap used ${sw_used}kB -> free ${after}kB"
  tg "swap 清债完成：${sw_used}kB → SwapFree ${after}kB（周清窗口，安全阈值内）"
else
  log "FAIL: swapoff/swapon 失败（rc=$?）"
  tg "swap 清债失败：swapoff/swapon 报错，请人工检查 /var/log/noda-swap-guard.log"
fi
