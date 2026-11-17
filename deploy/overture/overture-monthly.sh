#!/bin/sh
# overture-monthly.sh — Overture NZ places 月度自动链（r4s 宿主 root cron）
# noda-apps #392 WS1 T6。链：duckdb 环境自检（缺则装）→ T1 下载（日期版本目录，
# 不覆盖上月）→ 触发 apps 侧 crawl-overture job（HTTP trigger；该 job 内含
# UpsertItems + 失效 diff expireOvertureClosedPlaces——apps T3 交付，本脚本只触发）
# → TG 回执；任一步失败 TG 告警并以非零退出（cron 行据此上 hb fail）。
#
# 安装（r4s，root；编排者执行）：
#   mkdir -p /mnt/mmc1-4/System/Scripts/overture
#   scp deploy/overture/fetch-overture-nz.py deploy/overture/overture-monthly.sh \
#       root@r4s:/mnt/mmc1-4/System/Scripts/overture/
#   chmod +x /mnt/mmc1-4/System/Scripts/overture/*.sh /mnt/mmc1-4/System/Scripts/overture/*.py
# crontab 行（已同步 deploy/crontab-r4s-host；⚠ 假定 r4s 本机时区=NZ，先 `date` 核对，
#   非 NZ 时区需换算：NZST=UTC+12 / NZDT=UTC+13）：
#   0 6 1 * * /mnt/mmc1-4/System/Scripts/overture/overture-monthly.sh >> /var/log/noda-overture-monthly.log 2>&1 && /mnt/mmc1-4/System/Scripts/hb ok r4s:overture-monthly '0 6 1 * *' || /mnt/mmc1-4/System/Scripts/hb fail r4s:overture-monthly '0 6 1 * *'
# 前置：apps 侧 crawl-overture job 已部署（overture.go adapter + NEARBY_OVERTURE_FILE
#   指向 $DATA_DIR/overture-nz-latest.jsonl 稳定符号链接，且该宿主目录已挂载进
#   noda-jobs-prod 容器——挂载编排见部署清单）。
#
# env 覆盖：OVERTURE_DATA_DIR / OVERTURE_RELEASE / OVERTURE_FORCE=1（重跑当月）
#   OVERTURE_DRY_RUN=1 或 --dry-run（干跑：只打印动作，不触网/不 docker/不 pip）
#   OVERTURE_JOBS_CONTAINER / OVERTURE_WAIT_TIMEOUT（默认 3300s=55min，略大于
#   apps scheduler externalManualTriggerTimeout 50min）
#
# 幂等/断点：成功后写 $DATA_DIR/.done-<YYYY-MM> 标记，同月重跑跳过（OVERTURE_FORCE=1
#   强制）；下载失败可整月重跑（JSONL 原子替换）；lock 目录防双跑（26h 判陈旧）。

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FETCH="$SCRIPT_DIR/fetch-overture-nz.py"
DATA_DIR="${OVERTURE_DATA_DIR:-/mnt/mmc1-4/Data/overture}"
MONTH=$(date +%Y-%m)
OUT_DIR="$DATA_DIR/$MONTH"
OUT="$OUT_DIR/overture-nz.jsonl"
STATS="$OUT.stats.json"
MARKER="$DATA_DIR/.done-$MONTH"
LATEST="$DATA_DIR/overture-nz-latest.jsonl"
LOCK="$DATA_DIR/.monthly-lock"
VENV="$SCRIPT_DIR/venv"
PYLIB="$SCRIPT_DIR/pylib"
JOBS_CONTAINER="${OVERTURE_JOBS_CONTAINER:-noda-jobs-prod}"
JOB="crawl-overture"
TRIGGER_URL="http://127.0.0.1:3016/api/cron/trigger/$JOB"
STATUS_URL="http://127.0.0.1:3016/api/cron/status"
WAIT_TIMEOUT="${OVERTURE_WAIT_TIMEOUT:-3300}"
TRIGGER_LAND_TIMEOUT=300      # trigger 发出后 job 未开始的上限
TG_SCRIPT="${OVERTURE_TG_SCRIPT:-/mnt/mmc1-4/System/Scripts/telegram-alert.sh}"
KEEP_MONTHS=12

DRYRUN="${OVERTURE_DRY_RUN:-0}"
[ "${1:-}" = "--dry-run" ] && DRYRUN=1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

tg() {
    if [ "$DRYRUN" = 1 ]; then log "[dryrun] TG: $*"; return 0; fi
    sh "$TG_SCRIPT" "overture-monthly $MONTH: $*" >/dev/null 2>&1 || true
}

fail() {
    log "FAIL: $*"
    # 注意：变量一律 ${VAR} 形式——$VAR 后紧跟多字节字符会被部分 sh（macOS
    # bash3.2 sh 模式）误并入变量名触发 set -u 假错
    tg "❌ $*（日志 /var/log/noda-overture-monthly.log；stats ${STATS}）"
    exit 1
}

# ---------------------------------------------------------------- 锁 + 幂等

lock_acquire() {
    if mkdir "$LOCK" 2>/dev/null; then
        date +%s > "$LOCK/ts"
        trap 'rm -rf "$LOCK"' EXIT
        trap 'rm -rf "$LOCK"; exit 1' INT TERM
        return 0
    fi
    now=$(date +%s)
    lt=$(cat "$LOCK/ts" 2>/dev/null || echo 0)
    age=$((now - lt))
    if [ "$age" -gt 93600 ]; then          # 26h 判陈旧（链全程 ≈1.5h 上界）
        log "清除陈旧 lock（age ${age}s）"
        rm -rf "$LOCK"
        mkdir "$LOCK" || fail "lock 竞争失败"
        date +%s > "$LOCK/ts"
        trap 'rm -rf "$LOCK"' EXIT
        trap 'rm -rf "$LOCK"; exit 1' INT TERM
        return 0
    fi
    fail "已有实例在跑（lock age ${age}s）"
}

mkdir -p "$DATA_DIR" || { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL: 数据目录不可建 $DATA_DIR" >&2; exit 1; }

if [ -f "$MARKER" ] && [ "${OVERTURE_FORCE:-0}" != "1" ]; then
    log "本月已完成（$MARKER 存在），跳过。OVERTURE_FORCE=1 可强制重跑。"
    exit 0
fi
lock_acquire
log "START month=$MONTH data_dir=$DATA_DIR dryrun=$DRYRUN"

# ---------------------------------------------------------------- 1. duckdb 自检

PY=""
export PYTHONPATH="${PYTHONPATH:-}"

if [ "$DRYRUN" = 1 ]; then
    PY="python3(dryrun)"
    log "[dryrun] 步骤1 跳过 duckdb 自检（真实运行：检查 $VENV / 系统 python3，缺则 pip 安装 duckdb 并预热 httpfs）"
else
    if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import duckdb" >/dev/null 2>&1; then
        PY="$VENV/bin/python"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import duckdb" >/dev/null 2>&1; then
        PY="python3"
    else
        log "duckdb 缺失，安装到固定路径 ${VENV}（回退 pylib）"
        if command -v python3 >/dev/null 2>&1 \
            && python3 -m venv "$VENV" 2>/dev/null \
            && "$VENV/bin/pip" install --quiet duckdb >/dev/null 2>&1 \
            && "$VENV/bin/python" -c "import duckdb" >/dev/null 2>&1; then
            PY="$VENV/bin/python"
        elif command -v python3 >/dev/null 2>&1 \
            && python3 -m pip install --quiet --target "$PYLIB" duckdb >/dev/null 2>&1; then
            PYTHONPATH="$PYLIB${PYTHONPATH:+:$PYTHONPATH}"
            export PYTHONPATH
            PY="python3"
        else
            fail "duckdb 环境安装失败（venv 与 pip --target 均不可用）"
        fi
    fi
    # httpfs 扩展预热（首次从 extensions.duckdb.org 下载并缓存）
    "$PY" -c "import duckdb; c=duckdb.connect(); c.execute('INSTALL httpfs'); c.execute('LOAD httpfs')" \
        || fail "duckdb httpfs 扩展不可用（网络/缓存问题）"
    DDB_VER=$("$PY" -c 'import duckdb; print(duckdb.__version__)' 2>/dev/null || echo '?')
    log "步骤1 duckdb 自检通过（${PY}, duckdb ${DDB_VER}）"
fi

# ---------------------------------------------------------------- 2. T1 下载

RELEASE_ARG=""
[ -n "${OVERTURE_RELEASE:-}" ] && RELEASE_ARG="--release $OVERTURE_RELEASE"

if [ "$DRYRUN" = 1 ]; then
    log "[dryrun] 步骤2 跳过下载：$PY $FETCH $RELEASE_ARG --out ${OUT}（单次 S3 全 bbox 扫描 ~25min）"
else
    log "步骤2 下载开始：release=${OVERTURE_RELEASE:-默认} out=$OUT"
    # shellcheck disable=SC2086
    "$PY" "$FETCH" $RELEASE_ARG --out "$OUT" || fail "T1 下载失败（fetch-overture-nz.py 非零退出）"
    [ -f "$STATS" ] || fail "stats 缺失：$STATS"
fi

# ---------------------------------------------------------------- 3. 产物 sanity + latest 符号链接

if [ "$DRYRUN" = 0 ]; then
    KEPT=$(python3 -c "import json;print(json.load(open('$STATS'))['stages']['kept'])" 2>/dev/null || echo -1)
    [ "$KEPT" -gt 0 ] 2>/dev/null || fail "sanity 不通过：stats kept=${KEPT}（白名单/上游 schema 变化?）"
    NOCITY=$(python3 -c "import json;print(json.load(open('$STATS'))['dropped']['no_city'])" 2>/dev/null || echo "?")
    MINS=$(python3 -c "import json;print(json.load(open('$STATS')).get('minutes','?'))" 2>/dev/null || echo "?")
    CITIES=$(python3 -c "
import json
c = json.load(open('$STATS'))['cities']
print(', '.join('%s=%d' % kv for kv in sorted(c.items(), key=lambda x: -x[1])[:3]))" 2>/dev/null || echo "?")
    ln -sfn "$MONTH/overture-nz.jsonl" "$LATEST" || fail "latest 符号链接失败"
    SIZE=$(wc -c < "$OUT" 2>/dev/null || echo 0)
    log "步骤3 sanity 通过：kept=$KEPT no_city=$NOCITY ${MINS}min ${SIZE}B cities[$CITIES]"
else
    KEPT="?"; NOCITY="?"; MINS="?"; CITIES="?"; SIZE=0
    log "[dryrun] 步骤3 跳过 sanity/latest 符号链接（$LATEST → $MONTH/overture-nz.jsonl）"
fi

# ---------------------------------------------------------------- 4. 触发 crawl-overture（含失效 diff）

jobs_status() {   # 容器内 3016 状态端点（noda-jobs 同镜像，wget 已由 ops 惯例验证）
    docker exec "$JOBS_CONTAINER" wget -qO- -T 20 "$STATUS_URL" 2>/dev/null
}

state_of() {      # $1=job $2=pre_startedAt；输出 RUNNING|WAIT|DONE<TAB>status
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
job, pre = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); raise SystemExit
for j in d.get("jobs", []):
    if j.get("name") == job:
        if j.get("isRunning"):
            print("RUNNING"); raise SystemExit
        started = str((j.get("lastExecution") or {}).get("startedAt") or "-")
        if started != pre:
            st = (j.get("lastExecution") or {}).get("status", "")
            print("DONE\t%s" % st); raise SystemExit
        print("WAIT"); raise SystemExit
print("MISSING")
PYEOF
}

if [ "$DRYRUN" = 1 ]; then
    log "[dryrun] 步骤4 跳过触发：preflight(status 含 $JOB) → docker exec -d $JOBS_CONTAINER wget --post-data='' $TRIGGER_URL → 轮询 $STATUS_URL 至完成（≤${WAIT_TIMEOUT}s）"
    log "[dryrun] 步骤5 跳过：TG 回执 + $MARKER + 旧目录清理（保留 $KEEP_MONTHS 个月）"
    log "[dryrun] DONE（hb 由 cron 行按退出码上报）"
    exit 0
fi

log "步骤4 触发 ${JOB}（失效 diff 在 job 内执行——apps T3 expireOvertureClosedPlaces）"
PRE_JSON=$(jobs_status) || fail "noda-jobs 状态端点不可达（$JOBS_CONTAINER ${STATUS_URL}）"
echo "$PRE_JSON" | grep -q "\"$JOB\"" || fail "$JOB 未注册（apps T3 未部署?）"
PRE=$(printf '%s' "$PRE_JSON" | python3 - "$JOB" <<'PYEOF'
import json, sys
d = json.load(sys.stdin)
for j in d.get("jobs", []):
    if j.get("name") == sys.argv[1]:
        le = j.get("lastExecution") or {}
        print(le.get("startedAt") or "-")
        break
PYEOF
) || fail "解析 lastExecution 失败"

TRIGGER_OUT="/tmp/overture-trigger-$MONTH.json"
docker exec -d "$JOBS_CONTAINER" wget -qO "$TRIGGER_OUT" -T 3600 --post-data='' "$TRIGGER_URL" \
    || fail "trigger 发送失败（docker exec）"

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
land_deadline=$(( $(date +%s) + TRIGGER_LAND_TIMEOUT ))
while :; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || fail "$JOB 等待超时（${WAIT_TIMEOUT}s；查 docker logs ${JOBS_CONTAINER}）"
    state=$(jobs_status | state_of "$JOB" "$PRE")
    case "$state" in
        RUNNING)
            sleep 30
            ;;
        WAIT)
            [ "$now" -lt "$land_deadline" ] || fail "trigger 未生效（${TRIGGER_LAND_TIMEOUT}s 内 job 未启动；可能 409/容器异常）"
            sleep 10
            ;;
        DONE*)
            JOB_STATUS=$(printf '%s' "$state" | cut -f2)
            break
            ;;
        *)
            sleep 15     # ERR（容器/网络抖动）：总 deadline 兜底
            ;;
    esac
done
log "步骤4 job 结束：status=$JOB_STATUS"

# 触发响应（NearbyResult）回读进 TG 回执；读不到不致命
TRIGGER_RESP=$(docker exec "$JOBS_CONTAINER" cat "$TRIGGER_OUT" 2>/dev/null || echo "")
JOB_SUMMARY=$(printf '%s' "$TRIGGER_RESP" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    r = d.get('result') or {}
    print(str(r.get('summary') or r)[:200])
except Exception:
    print('')" 2>/dev/null || echo "")

# ---------------------------------------------------------------- 5. 收尾：TG 回执 + 幂等标记 + 清理

if [ "$JOB_STATUS" = "success" ]; then
    date +%s > "$MARKER"
    docker exec "$JOBS_CONTAINER" rm -f "$TRIGGER_OUT" 2>/dev/null || true
    # 旧月目录清理（保留最近 KEEP_MONTHS 个）
    for d in $(ls -1d "$DATA_DIR"/20[0-9][0-9]-[0-9][0-9] 2>/dev/null | sort -r | tail -n +$((KEEP_MONTHS + 1))); do
        log "清理旧月目录 $d"
        rm -rf "$d"
    done
    tg "✅ kept=$KEPT no_city=$NOCITY ${MINS}min $((SIZE / 1024 / 1024))MB cities[$CITIES] job=$JOB_STATUS ${JOB_SUMMARY:+摘要:$JOB_SUMMARY}"
    log "DONE kept=$KEPT job=$JOB_STATUS"
    exit 0
fi
fail "crawl-overture job 失败（status=${JOB_STATUS}；查 docker logs ${JOBS_CONTAINER}）"
