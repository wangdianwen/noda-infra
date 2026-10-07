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
# bash 3.2（macOS /bin/bash，Jenkins sh 同款）无关联数组——case 函数查找
preprod_url_for() {
  case "$1" in
    class)  echo "https://class-preprod.noda.co.nz/" ;;
    www)    echo "https://www-preprod.noda.co.nz/" ;;
    admin)  echo "https://admin-preprod.noda.co.nz/" ;;
    liuyao) echo "https://liuyao-preprod.noda.co.nz/" ;;
    nearby) echo "https://nearby-preprod.noda.co.nz/" ;;
    auth)   echo "https://auth-preprod.noda.co.nz/" ;;
    comment) echo "https://comments-preprod.noda.co.nz/" ;;
    snagme) echo "https://snagme-preprod.noda.co.nz/" ;;
    *) echo "" ;;
  esac
}
# all 层 API 探针：nearby 未反代 /api/health（nginx 只通 /api/nearby|user/*），与单班同口径
api_probe_for() {
  case "$1" in
    nearby) echo "/sitemap.xml" ;;
    *) echo "/api/health" ;;
  esac
}

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

child_trigger() { # $1=product $2=layer → stdout=子班构建号；失败 return 1
  local product="$1" layer="$2" http crumb hdr qitem n i out build="" p
  session_init
  crumb=$(crumb_header)
  hdr=$(mktemp /tmp/jenkins-batch.XXXXXX) && mv "$hdr" "$hdr.hdr" && hdr="$hdr.hdr"
  http=$(curl -s "${AUTH[@]}" -b "$JAR" -H "$crumb" -X POST \
    "$JENKINS/job/$CHILD_JOB/buildWithParameters" \
    --data "PRODUCT=$product" --data "LAYER=$layer" --data "DEPLOY_MODE=normal" \
    -D "$hdr" -w '%{http_code}' -o /dev/null) || http=000
  [ "$http" = "201" ] || { rm -f "$hdr"; echo "触发失败 HTTP=$http" >&2; return 1; }
  # Location 队列项 = 本次请求专属（防 lastBuild 抢号，trigger-and-approve.sh 同款）
  qitem=$(grep -i '^location:' "$hdr" | tail -1 | tr -d '\r' | awk '{print $2}' | sed 's:/*$::')
  rm -f "$hdr"
  if [ -n "$qitem" ] && [ "$qitem" != "/" ]; then
    beat_start "子班已受理（${product}，队列排队中）"
    for i in $(seq 1 60); do
      out=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$qitem/api/json" || true)
      if [ -n "$out" ]; then
        n=$(printf '%s' "$out" | json_field '(d.get("executable") or {}).get("number")' 2>/dev/null || true)
        if [ -n "$n" ] && [ "$n" != "None" ]; then build=$n; break; fi
      fi
      beat
      sleep 10
    done
  fi
  if [ -z "$build" ]; then
    echo "⚠️ 队列项未出队，回退 lastBuild 并按 PRODUCT 参数核对" >&2
    build=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
      "$JENKINS/job/$CHILD_JOB/api/json?tree=lastBuild%5Bnumber%5D" | json_field 'd["lastBuild"]["number"]')
    p=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
      "$JENKINS/job/$CHILD_JOB/$build/api/json?tree=actions%5Bparameters%5Bname,value%5D%5D" |
      json_field '"|".join(pp["value"] for a in d["actions"] for pp in a.get("parameters", []) if pp["name"] == "PRODUCT")' 2>/dev/null || echo "?")
    [ "$p" = "$product" ] || { echo "构建#$build PRODUCT=$p ≠ ${product}，疑似并行会话构建" >&2; return 1; }
  fi
  echo "$build"
}

child_wait_gate() { # $1=子班构建号 → 0=已到审批门 / 1=未到门即结束或超时
  local b="$1" i state
  beat_start "子班 #$b 构建+发 preprod 中"
  for i in $(seq 1 $((GATE_WAIT_TOTAL / GATE_POLL_INTERVAL))); do
    state=$(child_state "$b")
    case "$state" in
      false/*) echo "❌ 子班 #$b 未到审批门即结束：$state" >&2; return 1 ;;
    esac
    if [ "$(pending_count "$b")" != "0" ]; then return 0; fi
    beat
    sleep "$GATE_POLL_INTERVAL"
  done
  echo "❌ 子班 #$b 等门超时（${GATE_WAIT_TOTAL}s）" >&2
  return 1
}

probe_url() { # $1=url，3 次×10s（公网预发探测；-b 带会话仅为守卫统一，cookie 域名匹配不会发往公网）
  local url="$1" try
  for try in 1 2 3; do
    if curl -sf --max-time 15 -b "$JAR" -o /dev/null "$url"; then return 0; fi
    sleep 10
  done
  return 1
}

probe_preprod() { # $1=product $2=layer；static=根 URL 200 / all=根 URL+API 探针 200
  local url; url=$(preprod_url_for "$1")
  probe_url "$url" || return 1
  if [ "$2" = "all" ]; then probe_url "${url%/}$(api_probe_for "$1")" || return 1; fi
  return 0
}

resource_gate() { # r4s 五项门禁；探针缺失 fail-open（pipeline-stages.sh 同语义）
  (
    cd "$REPO_ROOT"
    # shellcheck disable=SC1091
    source scripts/lib/log.sh
    # shellcheck disable=SC1091
    source scripts/pipeline-stages.sh
    export SSH_KEY_FILE
    pipeline_resource_gate
  )
}

write_summary() {
  local tsv; tsv=$(tsv_path)
  {
    echo "产品 ｜ 状态 ｜ preprod ｜ 子班"
    awk -F'\t' '{ printf "%s ｜ %s ｜ %s ｜ %s\n", $1, ($3=="ok" ? "✅ preprod 就绪" : "❌ "($5==""?"未知":$5)), $4, ($2!="" && $2!="0" ? "#"$2 : "-") }' "$tsv"
  } > "$BATCH_STATE_DIR/summary.txt"
  cat "$BATCH_STATE_DIR/summary.txt"
}

cmd_phase1() {
  local products_str="$1" layer="$2" cooldown="$3"
  mkdir -p "$BATCH_STATE_DIR"
  local tsv; tsv=$(tsv_path); : > "$tsv"
  local items=() products=() item p
  if [ -z "${products_str// /}" ]; then
    products=("${ALL_PRODUCTS[@]}")
  else
    IFS=',' read -ra items <<< "$products_str"
    for item in "${items[@]}"; do
      p=$(printf '%s' "$item" | tr -d '[:space:]')
      [ -n "$p" ] && products+=("$p")
    done
  fi
  # bash 3.2 + set -u 下空数组展开会崩，且空集必是输入错误——显式报错
  if [ "${#products[@]}" -eq 0 ]; then
    echo "PRODUCTS 解析为空（输入：[$products_str]），合法：${ALL_PRODUCTS[*]}" >&2
    exit 2
  fi
  for p in "${products[@]}"; do
    if [ -z "$(preprod_url_for "$p")" ]; then
      echo "未知产品：${p}（合法：${ALL_PRODUCTS[*]}）" >&2; exit 2
    fi
  done
  local total=${#products[@]} idx=0 build probe note
  for p in "${products[@]}"; do
    idx=$((idx + 1))
    echo "━━━━━ [$idx/$total] ${p}（LAYER=${layer}）━━━━━"
    build=""; probe="fail"; note=""
    if [ "${DRY_RUN:-0}" = "1" ]; then
      build="0"; probe="ok"; note="dry-run"
      echo "[dry-run] 跳过触发/等门/探活"
    else
      if ! resource_gate; then note="r4s 资源门禁超时（900s 未自愈）"; fi
      if [ -z "$note" ]; then
        if build=$(child_trigger "$p" "$layer"); then
          if child_wait_gate "$build"; then
            if probe_preprod "$p" "$layer"; then probe="ok"; else note="preprod 探活失败（3 次×10s）"; fi
          else
            note="子班未到审批门即失败"
          fi
        else
          note="触发失败"
        fi
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$build" "$probe" "$(preprod_url_for "$p")" "$note" >> "$tsv"
    if [ "$probe" = "ok" ]; then
      tg "📦 批量发布 [$idx/$total] ${p}：✅ preprod 就绪 $(preprod_url_for "$p")（班 #${build}）"
    else
      tg "📦 批量发布 [$idx/$total] ${p}：❌ ${note}（批量门上会标注，继续下一产品）"
    fi
    if [ "$idx" -lt "$total" ]; then sleep_with_beat "$cooldown"; fi
  done
  write_summary
}
cmd_phase3() { # $1=cooldown；逐个代批 ✅ 产品，任一失败立即停损
  local cooldown="$1"
  local tsv; tsv=$(tsv_path)
  local p build probe url note state ok_count=0 dry
  dry="${DRY_RUN:-0}"
  while IFS=$'\t' read -r p build probe url note; do
    [ -n "$p" ] || continue
    if [ "$probe" != "ok" ]; then
      echo "⏭ 跳过 ${p}（preprod 未就绪：${note:-未验证}）"
      continue
    fi
    if [ "$dry" = "1" ]; then
      echo "[dry-run] 将代批 #${build} ${p} → deploy_prod，随后守望子班完成"
      continue
    fi
    echo "━━━━━ 🚀 ${p} 部署 prod（代批班 #${build}）━━━━━"
    if ! JOB_NAME="$CHILD_JOB" "$DIR/gate-action.sh" "$build" deploy_prod; then
      tg "🛑 批量发布中止：${p} 代批失败（班 #${build}）。已上 prod ${ok_count} 个；失败班与 -old 锚点见 Jenkins"
      echo "❌ ${p} 代批失败——停止后续产品（已发布内容不动，-old 锚点未动，可手工回滚）" >&2
      exit 1
    fi
    beat_start "子班 #${build}（${p}）prod 发布中"
    state="parse-error"
    while :; do
      state=$(child_state "$build")
      case "$state" in
        false/*) break ;;
      esac
      beat
      sleep "$GATE_POLL_INTERVAL"
    done
    if [ "$state" != "false/SUCCESS" ]; then
      tg "🛑 批量发布中止：${p} 子班 #${build} 结束=${state}（预期 SUCCESS）。已上 prod ${ok_count} 个；该产品 -old 锚点可回滚，后续产品未动"
      echo "❌ ${p} prod 发布失败（${state}）——停止后续产品" >&2
      exit 1
    fi
    ok_count=$((ok_count + 1))
    tg "🚀 批量发布 [${p}] prod 完成（累计 ${ok_count}）"
    sleep_with_beat "$cooldown"
  done < "$tsv"
  if [ "$dry" != "1" ]; then tg "✅ 批量发布全程完成：${ok_count} 个产品已上 prod"; fi
  echo "✅ phase3 完成（${ok_count} 个产品）"
}

cmd_abort_all() { # 幂等：只处理仍 pending 的子班门
  local tsv p build probe url note n=0
  tsv=$(tsv_path)
  if [ ! -f "$tsv" ]; then echo "无状态文件，无需清理"; return 0; fi
  while IFS=$'\t' read -r p build probe url note; do
    [ -n "$build" ] && [ "$build" != "0" ] || continue
    if [ "${DRY_RUN:-0}" = "1" ]; then echo "[dry-run] 将 abort 子班 #${build}（${p}）"; continue; fi
    if [ "$(pending_count "$build")" = "0" ]; then
      echo "ℹ️ 子班 #${build}（${p}）无 pending 门（已自行结束），跳过"
      continue
    fi
    if JOB_NAME="$CHILD_JOB" "$DIR/gate-action.sh" "$build" abort; then
      echo "🧹 子班 #${build}（${p}）已 abort"; n=$((n + 1))
    else
      echo "⚠️ 子班 #${build} abort 失败（可能刚被处理），请人工核对"
    fi
  done < "$tsv"
  echo "清理完成：abort ${n} 个子班"
}

main() {
  local cmd="${1:?用法: batch-release.sh phase1|phase3|abort-all}"
  case "$cmd" in
    phase1)    cmd_phase1 "${2:-}" "${3:-static}" "${4:-60}" ;;
    phase3)    cmd_phase3 "${2:-60}" ;;
    abort-all) cmd_abort_all ;;
    *) echo "未知子命令：${cmd}（phase1|phase3|abort-all）"; exit 2 ;;
  esac
}

main "$@"
