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
        elif command -v docker >/dev/null 2>&1; then
            # 2026-11-18 首跑判例：r4s=iStoreOS musl（OpenWrt 系），venv 模块缺失且
            # duckdb 无 musl wheel（pip 走源码构建，CMake 缺失失败）——宿主 python 不可
            # 用，第三级兜底改走 docker glibc 容器跑 T1（python:3.12-slim manylinux
            # aarch64 wheel 即装即用）。pip/duckdb 扩展缓存持久化到宿主避免月度重下。
            USE_DOCKER_PY=1
            PY="docker:${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim}"
        else
            fail "duckdb 环境安装失败（venv 与 pip --target 均不可用，且无 docker 兜底）"
        fi
    fi
    CACHE_DIR="$SCRIPT_DIR/.dcache"
    if [ "$USE_DOCKER_PY" = 1 ]; then
        mkdir -p "$CACHE_DIR/pip" "$CACHE_DIR/duckdb" "$OUT_DIR" \
            || fail "docker 兜底缓存/输出目录不可建"
        docker pull -q "${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim}" >/dev/null 2>&1 \
            || fail "docker pull ${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim} 失败"
        # httpfs 扩展预热（容器内缓存卷持久化，首次从 extensions.duckdb.org 下载）
        docker run --rm \
            -v "$SCRIPT_DIR":/opt/overture:ro \
            -v "$CACHE_DIR/pip":/root/.cache/pip \
            -v "$CACHE_DIR/duckdb":/root/.duckdb \
            "${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim}" \
            sh -c "pip install --quiet duckdb && python -c 'import duckdb; c=duckdb.connect(); c.execute(\"INSTALL httpfs\"); c.execute(\"LOAD httpfs\")'" \
            || fail "docker 兜底 duckdb/httpfs 不可用（网络/缓存问题）"
        DDB_VER=$(docker run --rm \
            -v "$CACHE_DIR/pip":/root/.cache/pip \
            "${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim}" \
            sh -c "pip install --quiet duckdb && python -c 'import duckdb; print(duckdb.__version__)'" \
            2>/dev/null || echo '?')
        log "步骤1 duckdb 自检通过（docker 兜底 ${PY}, duckdb ${DDB_VER}）"
    else
        # httpfs 扩展预热（首次从 extensions.duckdb.org 下载并缓存）
        "$PY" -c "import duckdb; c=duckdb.connect(); c.execute('INSTALL httpfs'); c.execute('LOAD httpfs')" \
            || fail "duckdb httpfs 扩展不可用（网络/缓存问题）"
        DDB_VER=$("$PY" -c 'import duckdb; print(duckdb.__version__)' 2>/dev/null || echo '?')
        log "步骤1 duckdb 自检通过（${PY}, duckdb ${DDB_VER}）"
    fi
fi

# ---------------------------------------------------------------- 2. T1 下载

RELEASE_ARG=""
[ -n "${OVERTURE_RELEASE:-}" ] && RELEASE_ARG="--release $OVERTURE_RELEASE"

if [ "$DRYRUN" = 1 ]; then
    log "[dryrun] 步骤2 跳过下载：$PY $FETCH $RELEASE_ARG --out ${OUT}（单次 S3 全 bbox 扫描 ~25min）"
elif [ "${USE_DOCKER_PY:-0}" = 1 ]; then
    log "步骤2 下载开始（docker 兜底）：release=${OVERTURE_RELEASE:-默认} out=$OUT"
    docker run --rm \
        -v "$SCRIPT_DIR":/opt/overture:ro \
        -v "$DATA_DIR":/data \
        -v "$CACHE_DIR/pip":/root/.cache/pip \
        -v "$CACHE_DIR/duckdb":/root/.duckdb \
        -w /opt/overture \
        "${OVERTURE_DOCKER_PY_IMAGE:-python:3.12-slim}" \
        sh -c "pip install --quiet duckdb && python fetch-overture-nz.py $RELEASE_ARG --out /data/$MONTH/overture-nz.jsonl" \
        || fail "T1 下载失败（docker 兜底 fetch-overture-nz.py 非零退出）"
    [ -f "$STATS" ] || fail "stats 缺失：$STATS"
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

running_of() {    # $1=job；stdin 收 status JSON；输出 RUNNING|IDLE|ERR|MISSING
    # ⚠️ python 数据一律 env 传参（`-c` 形态），禁 heredoc——heredoc 程序体会
    # 占用/串接 stdin，json.load(sys.stdin) 必炸（2026-11-19「解析 lastExecution
    # 失败」两轮判例；env 传参是唯一稳态形态）。
    STATUS_JSON="$(cat)" JOB="$1" python3 -c '
import json, os
try:
    d = json.loads(os.environ["STATUS_JSON"])
except Exception:
    print("ERR"); raise SystemExit
for j in d.get("jobs", []):
    if j.get("name") == os.environ["JOB"]:
        print("RUNNING" if j.get("isRunning") else "IDLE"); raise SystemExit
print("MISSING")
'
}

resp_of() {       # stdin 收 trigger 同步响应；输出 DONE<TAB>summary | ERRRESP<TAB>body | PARSE_FAIL
    RESP_JSON="$(cat)" python3 -c '
import json, os
try:
    d = json.loads(os.environ["RESP_JSON"])
except Exception:
    print("PARSE_FAIL"); raise SystemExit
r = d.get("result")
if r is None:
    print("ERRRESP\t%s" % str(d.get("error") or d)[:200]); raise SystemExit
print("DONE\t%s" % str(r.get("summary") or r)[:200])
'
}

if [ "$DRYRUN" = 1 ]; then
    log "[dryrun] 步骤4 跳过触发：preflight(status 含 $JOB) → 清响应文件 → docker exec -d $JOBS_CONTAINER wget --post-data='' $TRIGGER_URL → 轮询响应文件至落盘（同步触发响应=执行结果，≤${WAIT_TIMEOUT}s）"
    log "[dryrun] 步骤5 跳过：TG 回执 + $MARKER + 旧目录清理（保留 $KEEP_MONTHS 个月）"
    log "[dryrun] DONE（hb 由 cron 行按退出码上报）"
    exit 0
fi

log "步骤4 触发 ${JOB}（同步触发：HTTP 响应=执行结果；失效 diff 在 job 内执行——apps T3 expireOvertureClosedPlaces）"
# preflight 带重试：2026-11-18 首跑判例——状态端点偶发瞬时抖动（wget -qO- 空/截断
# 输出但退出 0），单次探测即 fail 太脆；3 次×5s 间隔重试后仍失败才判死。
pre_json_get() {
    i=0
    while [ "$i" -lt 3 ]; do
        out=$(jobs_status) || out=""
        if [ -n "$out" ] && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
            printf '%s' "$out"
            return 0
        fi
        i=$((i + 1))
        [ "$i" -lt 3 ] && sleep 5
    done
    return 1
}
PRE_JSON=$(pre_json_get) || fail "noda-jobs 状态端点不可达/非 JSON（重试 3 次；$JOBS_CONTAINER ${STATUS_URL}）"
echo "$PRE_JSON" | grep -q "\"$JOB\"" || fail "$JOB 未注册（apps T3 未部署?）"

# 完成检测（2026-11-19 判例）：crawl-overture 不挂 addCron（#400，纯 HTTP 触发），
# 而 apps triggerImpl→triggerNearby 手动路径不写内存 lastExecution（impl.go，仅
# cron 路径 nearbyRun 写 setLastSummary）——状态端点的 startedAt 快照不等轮询对
# 该 job 永远 WAIT，300s 后必假报「trigger 未生效」（isRunning 会置位但
# lastExecution 恒 null，快照比较无从变化）。改为等待同步触发的响应文件：HTTP 200
# 返回即执行完成，body=NearbyResult 全量；isRunning 仍可作 landing 佐证。
TRIGGER_OUT="/tmp/overture-trigger-$MONTH.json"
docker exec "$JOBS_CONTAINER" rm -f "$TRIGGER_OUT" 2>/dev/null || true   # 残留响应会令轮询瞬间误判完成
docker exec -d "$JOBS_CONTAINER" wget -qO "$TRIGGER_OUT" -T 3600 --post-data='' "$TRIGGER_URL" \
    || fail "trigger 发送失败（docker exec）"

deadline=$(( $(date +%s) + WAIT_TIMEOUT ))
land_deadline=$(( $(date +%s) + TRIGGER_LAND_TIMEOUT ))
seen_running=0
idle_since=0
JOB_STATUS=""
JOB_SUMMARY=""
while :; do
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || fail "$JOB 等待超时（${WAIT_TIMEOUT}s；查 docker logs ${JOBS_CONTAINER}）"
    parsed=$(docker exec "$JOBS_CONTAINER" cat "$TRIGGER_OUT" 2>/dev/null | resp_of)
    case "$parsed" in
        DONE*)
            JOB_STATUS="success"
            JOB_SUMMARY=$(printf '%s' "$parsed" | cut -f2)
            break
            ;;
        ERRRESP*)
            JOB_STATUS="failure"
            JOB_SUMMARY=$(printf '%s' "$parsed" | cut -f2)
            break
            ;;
    esac
    run=$(jobs_status | running_of "$JOB")
    case "$run" in
        RUNNING)
            seen_running=1
            idle_since=0
            ;;
        IDLE)
            if [ "$seen_running" = 1 ]; then
                # 执行体已结束而响应迟迟不落盘：非 2xx（busybox wget 不存错误 body）
                [ "$idle_since" = 0 ] && idle_since=$now
                [ $((now - idle_since)) -gt 120 ] && fail "$JOB 已结束但 trigger 响应未落盘（非 2xx=执行失败——查 docker logs ${JOBS_CONTAINER}）"
            fi
            [ "$now" -lt "$land_deadline" ] || fail "trigger 未生效（${TRIGGER_LAND_TIMEOUT}s 内 job 未启动且无响应；可能 409/快速失败/容器异常——查 docker logs ${JOBS_CONTAINER}）"
            ;;
        *)
            sleep 15    # ERR/MISSING（容器/网络抖动）：总 deadline 兜底
            ;;
    esac
    sleep 30
done
log "步骤4 job 结束：status=$JOB_STATUS${JOB_SUMMARY:+ 摘要:$JOB_SUMMARY}"

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
