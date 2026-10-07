#!/usr/bin/env bash
# batch-release.sh — noda-release-all 全站批量发布编排器
# spec: docs/superpowers/specs/2026-10-08-release-all-batch-deploy-design.md
# 用法（由 Jenkinsfile.batch 调用，也可手动 CLI 演练）：
#   batch-release.sh phase1 "<PRODUCTS 逗号分隔，空=全部>" <LAYER> <COOLDOWN_SECONDS>
#   batch-release.sh phase3 <COOLDOWN_SECONDS>
#   batch-release.sh abort-all
# DRY_RUN=1 演练编排路径：不触发构建/不代批/不探活，状态文件照写（probe=ok）
# 状态：$BATCH_STATE_DIR/products.tsv（product⇥build⇥probe⇥preprod_url⇥note）+ summary.txt
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
CHILD_JOB="noda-apps"
JENKINS="${JENKINS_URL:-http://localhost:8080}"
BATCH_STATE_DIR="${BATCH_STATE_DIR:-$PWD/.batch-state}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-60}"
GATE_WAIT_TOTAL="${GATE_WAIT_TOTAL:-21600}"   # 子班审批门 6h 超时对齐
GATE_POLL_INTERVAL=15
ALL_PRODUCTS=(class www admin liuyao nearby auth comment snagme)
# shellcheck disable=SC2034
declare -A PREPROD_URL=(
  [class]="https://class-preprod.noda.co.nz/"   [www]="https://www-preprod.noda.co.nz/"
  [admin]="https://admin-preprod.noda.co.nz/"   [liuyao]="https://liuyao-preprod.noda.co.nz/"
  [nearby]="https://nearby-preprod.noda.co.nz/" [auth]="https://auth-preprod.noda.co.nz/"
  [comment]="https://comments-preprod.noda.co.nz/" [snagme]="https://snagme-preprod.noda.co.nz/"
)
# all 层 API 探针：nearby 未反代 /api/health（nginx 只通 /api/nearby|user/*），与单班同口径
# shellcheck disable=SC2034
declare -A API_PROBE=( [nearby]="/sitemap.xml" )

# admin basic auth（与 trigger-and-approve.sh 同款）
# shellcheck disable=SC1091
source "$DIR/config/jenkins-admin.env"
AUTH=(-u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
JAR=$(mktemp /tmp/jenkins-batch.XXXXXX) && mv "$JAR" "$JAR.jar" && JAR="$JAR.jar"
trap 'rm -f "$JAR"' EXIT

json_field() {
  python3 -c '
import sys, json
d = json.load(sys.stdin, strict=False)
print(eval(sys.argv[1]))' "$1"
}

session_init() { curl -s --max-time 10 "${AUTH[@]}" -c "$JAR" "$JENKINS/login" >/dev/null; }

crumb_header() {
  curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$JENKINS/crumbIssuer/api/json" |
    json_field 'd["crumbRequestField"]+": "+d["crumb"]'
}

# beat：一切等待的可见性心跳（用户硬要求：在等什么/已等多久/多久复查）
BEAT_MSG=""; BEAT_T0=0; BEAT_LAST=0
beat_start() { BEAT_MSG="$1"; BEAT_T0=$(date +%s); BEAT_LAST=0; }
beat() {
  local now; now=$(date +%s)
  if [ $((now - BEAT_LAST)) -ge "$HEARTBEAT_INTERVAL" ]; then
    BEAT_LAST=$now
    echo "⏳ ${BEAT_MSG} ｜ 已等 $((now - BEAT_T0))s ｜ 每 ${GATE_POLL_INTERVAL}s 复查"
  fi
}

sleep_with_beat() { # $1=秒
  local remain="$1" chunk
  if [ "$remain" -le 0 ]; then return 0; fi
  beat_start "冷却/间隔等待"
  while [ "$remain" -gt 0 ]; do
    chunk=$(( remain > HEARTBEAT_INTERVAL ? HEARTBEAT_INTERVAL : remain ))
    sleep "$chunk"; remain=$((remain - chunk)); beat
  done
}

pending_count() { # $1=子班构建号 → pending 门数量
  local pend
  pend=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$CHILD_JOB/$1/wfapi/pendingInputActions" || true)
  printf '%s' "$pend" | json_field 'len(d)' 2>/dev/null || echo 0
}

child_state() { # $1=子班构建号 → "building/result"
  curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$CHILD_JOB/$1/api/json?tree=building,result" |
    json_field 'str(d["building"])+"/"+str(d["result"])' 2>/dev/null || echo "parse-error"
}

tsv_path() { echo "$BATCH_STATE_DIR/products.tsv"; }

tg() { "$DIR/tg-notify.sh" "$1" || true; }

cmd_phase1() { echo "TODO-task2"; return 1; }
cmd_phase3() { echo "TODO-task3"; return 1; }
cmd_abort_all() { echo "TODO-task3"; return 1; }

main() {
  local cmd="${1:?用法: batch-release.sh phase1|phase3|abort-all}"
  case "$cmd" in
    phase1)    cmd_phase1 "${2:-}" "${3:-static}" "${4:-60}" ;;
    phase3)    cmd_phase3 "${2:-60}" ;;
    abort-all) cmd_abort_all ;;
    *) echo "未知子命令：$cmd（phase1|phase3|abort-all）"; exit 2 ;;
  esac
}

main "$@"
