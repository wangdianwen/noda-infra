#!/bin/sh
# ============================================
# rl429-alert.sh — 反爬限流（429）风暴 TG 告警
# 2026-10-17 bot-hardening 阶段 2 monitoring。
# ============================================
# 安装位置：r4s:/mnt/mmc1-4/System/Scripts/rl429-alert.sh（本文件为仓库存档，
#   与 weed-watchdog/swap-debt-guard 同型——宿主职责项进 crontab-r4s-host）
# cron：*/10 * * * *（见 deploy/crontab-r4s-host）
#
# 数据源：/opt/noda/noda-infra/docker/volumes/ops-logs/rl429.log
#   （noda-static-prod 以 bind 卷写入的 429 JSON access log，字段顺序 =
#   nginx conf.d/ratelimit.conf log_format rl_json——固定 ip,surface,m,u,st,exempt,ua）
#
# 设计（iStoreOS BusyBox 约束：无 jq、date -d 功能残缺——避免日期算术）：
#   增量读取：.rl-alert.offset 记录上次扫描到的字节偏移，每次只处理新增字节
#   → "10 分钟窗口" 由 cron 周期天然成立，无需解析时间戳
#   阈值告警：(ip,surface) 新增 429 计数 >= RL429_ALERT_THRESHOLD（默认 20）
#     → 调 telegram-alert.sh；按 (ip,surface,小时) 去重（.rl-alert.state，
#     抓取风暴持续时每小时最多刷一次屏）
#   轮转兜底：raw 日志 >8MB → 移 archive/rl429-<ts>.log 并 USR1 让 nginx 重开，
#     offset 归零（低频路径：正常流量 429 天然稀少）
#   自愈：日志缺失/被轮转重置（文件 < offset）→ offset 归零全量读一次
# ============================================

BASE="/opt/noda/noda-infra/docker/volumes/ops-logs"
LOG="$BASE/rl429.log"
OFFSET="$BASE/.rl-alert.offset"
STATE="$BASE/.rl-alert.state"
TG="/mnt/mmc1-4/System/Scripts/telegram-alert.sh"
THRESHOLD="${RL429_ALERT_THRESHOLD:-20}"
MAX_SIZE=$((8 * 1024 * 1024))

tg() { [ -x "$TG" ] && "$TG" "$1" >/dev/null 2>&1 || true; }

# ---- 日志缺失/轮转兜底 ----
if [ ! -f "$LOG" ]; then
    echo 0 > "$OFFSET"
    exit 0
fi
log_size=$(wc -c < "$LOG" 2>/dev/null | tr -d ' ' || echo 0)
last_offset=$(cat "$OFFSET" 2>/dev/null || echo 0)
if [ "$log_size" -lt "$last_offset" ]; then
    # 文件被重置/轮转：全量重读
    last_offset=0
fi

# ---- 增量切片 ----
tail_bytes=$(( log_size - last_offset ))
chunk=$(dd if="$LOG" bs=1 skip="$last_offset" count="$tail_bytes" 2>/dev/null || true)
# 口径留档：offset 每轮推进到"当前文件尾"——若最后一行没写完（无换行），
# 本轮会把它当完整行丢弃（sed 只匹配含收尾引号的完整行），下一轮它不再
# 是"新增字节"→ 永久漏计该行。替代成本（回退 cursor 到最后 \n）在 BusyBox
# sh 里需要 awk 逐字节扫，得不偿失——429 告警阈值 20 起，漏计 1 行可忽略。
echo "$log_size" > "$OFFSET"

# ---- 聚合 (ip,surface) 计数 ----
counts=$(printf '%s\n' "$chunk" | sed -n 's/.*"ip":"\([^"]*\)".*"surface":"\([^"]*\)".*/\1|\2/p' | sort | uniq -c | sort -rn | head -5)
[ -n "$counts" ] || exit 0

# ---- 阈值判断 + 小时去重（counts 行形如 "N ip|surface"，ip 内无空格 [CF 边缘
# 校验过的单 IP 单值]）----
hour=$(date -u +%Y%m%d%H)
alert_body=""
while IFS=' ' read -r n ipsurface; do
    [ -n "$ipsurface" ] || continue
    ip=${ipsurface%%|*}
    surface=${ipsurface#*|}
    [ -n "$ip" ] && [ "$ip" != "$surface" ] || continue
    key="${ip}|${surface}|${hour}"
    if grep -qF "$key" "$STATE" 2>/dev/null; then
        continue
    fi
    if [ "$n" -ge "$THRESHOLD" ]; then
        sample=$(printf '%s\n' "$chunk" | grep -F "\"ip\":\"$ip\"" | tail -1 | cut -c1-240)
        alert_body="${alert_body}${ip} [${surface}] ${n} 次/10min
样例: ${sample}
"
        printf '%s\n' "$key" >> "$STATE"
    fi
done <<EOF
$counts
EOF

# state 收敛：留最近 200 行
if [ -f "$STATE" ]; then
    tail -n 200 "$STATE" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
fi

if [ -n "$alert_body" ]; then
    tg "[noda·限流告警] 窗口=10min 阈值=${THRESHOLD}
${alert_body}（详情 ssh r4s 后 tail ${LOG}）"
fi

# ---- 轮转兜底（低频）----
if [ "$log_size" -gt "$MAX_SIZE" ]; then
    mkdir -p "$BASE/archive"
    ts=$(date +%Y%m%d%H%M%S)
    mv "$LOG" "$BASE/archive/rl429-${ts}.log" 2>/dev/null || exit 0
    docker kill --signal=USR1 noda-static-prod >/dev/null 2>&1 || true
    echo 0 > "$OFFSET"
    tg "[noda·限流] rl429.log 轮转 → archive/rl429-${ts}.log（nginx 已 USR1 重开）"
fi
