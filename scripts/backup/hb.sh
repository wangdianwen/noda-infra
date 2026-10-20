#!/bin/bash
# hb.sh — shell 型 cron 的 admin/cronjobs 心跳上报（2026-10-21 cron 全量盘点接入）
#
# 背景：adminapi 的 cron-pull 环只认 HTTP GET /api/cron/status（CronStatus JSON），
# 容器外/宿主机的 shell 型 cron 无法原生接入。本脚本把单次执行结果合并进
# /tmp/cronhb/api/cron/status 静态 JSON（路径直映射 URL），由 supervisord 的
# busybox httpd(:3017) 对外提供；SERVICE_ENDPOINTS 注册 noda-ops-cron 后
# admin/cronjobs 页 60s 内可见（job 级 lastExecution = 最近一次成功/失败）。
#
# 用法（crontab 行尾追加）：
#   ... 原命令 ... && /app/backup/hb.sh ok <job名> '<schedule>' || /app/backup/hb.sh fail <job名> '<schedule>'
#   宿主机经 wrapper（deploy/hb → docker exec noda-ops）同参调用。
# schedule 为展示标签（如 '0 3 * * *'），可省略（默认 "cron"）。
#
# 形状对齐 adminapi cronpull.go：{"service","jobs":[{name,description,schedule,
# isActive,isRunning,lastExecution:{status,startedAt,finishedAt,durationMs,triggeredBy}}]}。
# status 取 success/failed（与 noda-jobs scheduler.Status 同 vocabulary）。
# durationMs 恒 null（shell 行尾上报无起点锚，展示层可容忍）；isRunning 恒 false。
# 原子性：flock 串行 + tmp 文件 mv；容器重建后状态从零自然重建（心跳语义，无历史诉求）。
set -euo pipefail

# noda-ops 运行时根文件系统只读（pipeline docker run --read-only）：心跳落 /tmp tmpfs
STATUS_FILE=/tmp/cronhb/api/cron/status
SERVICE="${HB_SERVICE:-noda-ops-cron}"
LOCK_DIR=/tmp/cronhb
mkdir -p "$LOCK_DIR/api/cron"

if [ "$#" -lt 2 ]; then
    echo "usage: hb.sh ok|fail <job> [schedule] [error摘要]" >&2
    exit 2
fi
verb="$1"; job="$2"; sched="${3:-cron}"; errmsg="${4:-}"
case "$verb" in
    ok)   st="success" ;;
    fail) st="failed" ;;
    *)    echo "hb.sh: verb 必须是 ok|fail" >&2; exit 2 ;;
esac

# 兼容从别的容器/宿主 exec 进来写别的 service 名（HB_SERVICE env 覆盖）
exec 9>"$LOCK_DIR/.hb.lock"
flock 9

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# 起始文件不存在时给骨架；jq 合并单 job（保留其它 job 的 lastExecution）
tmp="$(mktemp "$STATUS_FILE.tmp.XXXXXX")"
jq --arg svc "$SERVICE" --arg job "$job" --arg sched "$sched" \
   --arg st "$st" --arg now "$now" --arg err "$errmsg" '
    (if (type == "object" and has("jobs")) then . else {service:$svc, jobs:[]} end)
    | .service = $svc
    | .jobs = ((.jobs // []) | map(select(.name != $job))
        + [{name: $job,
            description: "shell cron 心跳上报（hb.sh）",
            schedule: $sched,
            isActive: true,
            isRunning: false,
            lastExecution: {status: $st,
                            startedAt: $now,
                            finishedAt: $now,
                            durationMs: null,
                            triggeredBy: "cron",
                            error: (if $err == "" then "" else $err end)}}])
' "$STATUS_FILE" > "$tmp" 2>/dev/null || \
    echo "{\"service\":\"$SERVICE\",\"jobs\":[]}" > "$tmp"
mv -f "$tmp" "$STATUS_FILE"
