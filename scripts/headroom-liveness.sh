#!/bin/bash
# headroom-liveness.sh — headroom-proxy 存活看门狗（launchd 每 5 分钟）
#
# 背景：2026-11-02 Docker Desktop 崩溃致 headroom-proxy / seaweedfs-stg 容器丢失，
#   headroom 挂了近一周无人察觉——ZCode 按 providerOrder 静默回退 deepseek 烧降级
#   配额，每周日容器巡检又只扫「运行中」容器，停止/丢失的容器完全盲区。本脚本补位。
#
# 行为：
#   1. 探活 GET http://127.0.0.1:8787/health（5s 超时）。
#   2. 失败时按容器状态自愈：停止 → docker start；运行中但探活失败 → docker restart；
#      容器丢失 → 无法自愈，TG 告警（修复：scripts/headroom-recreate.sh）。
#   3. 自愈后复检一次；仍未恢复或容器丢失 → TG 告警（同一故障期间 1h 冷却防轰炸）。
#   4. 恢复（含自愈成功）→ TG 恢复通知（若此前告警过）。
#
# 测试钩子（不打扰真实容器）：
#   HEADROOM_LIVENESS_URL=http://127.0.0.1:9/ HEADROOM_LIVENESS_NO_ACT=1
#   HEADROOM_LIVENESS_NO_TG=1 bash scripts/headroom-liveness.sh
set -u

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

URL="${HEADROOM_LIVENESS_URL:-http://127.0.0.1:8787/health}"
NO_ACT="${HEADROOM_LIVENESS_NO_ACT:-}"
NO_TG="${HEADROOM_LIVENESS_NO_TG:-}"
STATE_DIR="$HOME/.config/headroom"
FAILED_MARK="$STATE_DIR/liveness-failed"     # 存在=故障期间；内容=上次告警 epoch
COOLDOWN=3600

mkdir -p "$STATE_DIR"

tg_send()  # TG 推送（tg.env 0600，与 container-update-check 同源）
{
    [ -n "$NO_TG" ] && return 0
    ENVF="$HOME/project/website-gate/credentials/tg.env"
    [ -f "$ENVF" ] || return 0
    # shellcheck disable=SC1090
    . "$ENVF"
    [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] && \
        curl -fsS -m 20 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=$1" -o /dev/null
    return 0
}

healthy() { curl -fsS --max-time 5 "$URL" >/dev/null 2>&1; }

mark_failed() { date +%s > "$FAILED_MARK"; }
clear_failed() { rm -f "$FAILED_MARK"; }
last_alert() { cat "$FAILED_MARK" 2>/dev/null || echo 0; }

# ---------- 恢复分支 ----------
if healthy; then
    if [ -f "$FAILED_MARK" ]; then
        clear_failed
        echo "[$(date '+%F %T')] ✓ headroom 已恢复"
        tg_send "✅ headroom-proxy 已恢复（8787 探活通过）$(date '+%m-%d %H:%M')
此前故障期间 ZCode 曾静默回退 deepseek，现在已回到 z.ai 链路。"
    fi
    exit 0
fi

# ---------- 故障分支 ----------
STATE=$(docker inspect headroom-proxy --format '{{.State.Status}}' 2>/dev/null || echo missing)

if [ "$NO_ACT" != "1" ]; then
    case "$STATE" in
        exited|dead|created)
            echo "[$(date '+%F %T')] 容器 $STATE → docker start"
            docker start headroom-proxy >/dev/null 2>&1 || true ;;
        running)
            echo "[$(date '+%F %T')] 容器运行但探活失败 → docker restart"
            docker restart headroom-proxy >/dev/null 2>&1 || true ;;
        missing)
            echo "[$(date '+%F %T')] 容器丢失，无法自愈" ;;
    esac
fi

# 复检：最多 30s（丢失态跳过复检）
RECOVERED=""
if [ "$STATE" != "missing" ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep 3
        if healthy; then RECOVERED=1; break; fi
    done
fi

if [ -n "$RECOVERED" ]; then
    clear_failed
    echo "[$(date '+%F %T')] ✓ 自愈成功（$STATE → 已恢复）"
    tg_send "⚠️→✅ headroom-proxy 异常已自动恢复（状态 ${STATE}，自愈动作后探活通过）$(date '+%m-%d %H:%M')"
    exit 0
fi

# 持续故障：冷却期内静默，冷却期满重新告警
NOW=$(date +%s)
LAST=$(last_alert)
if [ -f "$FAILED_MARK" ] && [ $((NOW - LAST)) -lt "$COOLDOWN" ]; then
    echo "[$(date '+%F %T')] 仍未恢复（冷却期内，不重复告警）"
    exit 1
fi

case "$STATE" in
    missing)
        MSG="🚨 headroom-proxy 容器丢失（8787 探活失败且容器不存在）$(date '+%m-%d %H:%M')
影响：ZCode 已静默回退 deepseek 烧降级配额。
修复：bash ~/project/noda-infra/scripts/headroom-recreate.sh
（本告警每小时最多重发一次）" ;;
    *)
        MSG="🚨 headroom-proxy 异常未恢复（容器状态 ${STATE}，自愈动作无效）$(date '+%m-%d %H:%M')
影响：ZCode 已静默回退 deepseek 烧降级配额。
排查：docker logs headroom-proxy --tail 50
（本告警每小时最多重发一次）" ;;
esac
mark_failed
echo "[$(date '+%F %T')] 🚨 告警：$STATE 持续故障"
tg_send "$MSG"
exit 1
