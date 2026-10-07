# noda-release-all 全站批量发布 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 Jenkins 编排 job `noda-release-all`：一次触发批量发布产品子集（默认全部 8 站），逐产品发 preprod 后过**一个**批量审批门，再依次代批 prod，全程心跳可见、r4s 产品间门禁+冷却。

**Architecture:** noda-apps 单产品管线零改动。编排逻辑全部在 bash（`scripts/jenkins/batch-release.sh`，复用 trigger-and-approve.sh 的触发模式与 gate-action.sh 的代批模式），`jenkins/Jenkinsfile.batch` 只做薄胶水（跑 bash + Jenkins 原生 input 批量门），seed 脚本建 job。

**Tech Stack:** bash（Jenkins `sh` 步执行）、Jenkins declarative pipeline、Jenkins REST API（wfapi）、pipeline-stages.sh 既有函数、Telegram 通知。

**Spec:** `docs/superpowers/specs/2026-10-08-release-all-batch-deploy-design.md`

## Global Constraints

- noda-apps job / Jenkinsfile.apps / pipeline-stages.sh / trigger-and-approve.sh / gate-action.sh **零改动**。
- 一切 curl 必须带会话 cookie（`-b "$JAR"`；建会话的 login 那条用 `-c`）。
- JSON 解析一律 `strict=False`（控制字符容忍）。
- API `tree=` 查询的 `[]` 必须 `%5B%5D` 编码（zsh glob 坑）。
- mktemp 必须 `XXXXXX` 后缀再 `mv` 改后缀（macOS 坑，#654 实证）。
- 调 gate-action.sh 必须前缀 `JOB_NAME="$CHILD_JOB"`（pipeline 内 `JOB_NAME` 是编排班自己，泄漏会批错 job）。
- TG 通知 fire-and-forget，永不阻塞。
- DEPLOY_MODE 固定 `normal`（fast 与批量门语义冲突）。
- 用户硬要求：一切等待必须有「⏳ 在等什么 ｜ 已等多久 ｜ 多久复查」心跳输出。
- **spec 口径修正（一处）**：spec 写「Phase 3 探活 prod」——落地口径为**子班结果 SUCCESS 即视为 prod 就绪**（子班 Deploy Prod 内置发布校验；prod 域名清单无集中维护，不在编排器硬编码 8 个域名）。

## File Structure

- Create: `scripts/jenkins/batch-release.sh` — 编排器（phase1/phase3/abort-all 三个子命令 + DRY_RUN）
- Create: `scripts/jenkins/batch-release-test.sh` — 守卫测试（needle + DRY_RUN 行为）
- Create: `jenkins/Jenkinsfile.batch` — 薄胶水 pipeline
- Create: `scripts/jenkins/init.groovy.d/15-pipeline-job-noda-release-all.groovy` — job seed（配置即代码）

---

### Task 1: batch-release.sh 骨架 + 公共件 + 守卫测试壳

**Files:**
- Create: `scripts/jenkins/batch-release.sh`
- Create: `scripts/jenkins/batch-release-test.sh`

**Interfaces:**
- Produces: `main "$@"` 子命令分发（phase1/phase3/abort-all）；公共函数 `json_field` `session_init` `crumb_header` `beat_start` `beat` `pending_count` `child_state` `sleep_with_beat`；状态目录约定 `$BATCH_STATE_DIR/products.tsv`（TSV 五列：product/build/probe/preprod_url/note）与 `summary.txt`。

- [ ] **Step 1: 写守卫测试（先失败）**

创建 `scripts/jenkins/batch-release-test.sh`：

```bash
#!/usr/bin/env bash
# batch-release-test.sh — batch-release.sh 守卫测试（needle + DRY_RUN 行为）
# 模式沿用 trigger-and-approve-test.sh：bash 语法 + 历史踩坑 needle + dry-run 行为
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
S="$DIR/batch-release.sh"
FAIL=0
need() { # need <描述> <命令>
  if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=1; fi
}

echo "== needle 守卫 =="
need "bash 语法" "bash -n $S"
need "全部 curl 带会话 cookie" "! grep -nE 'curl -s' $S | grep -vE -- '-[bc] \"\\\$JAR\"'"
need "JSON 解析 strict=False" "grep -q 'strict=False' $S"
if python3 - "$S" << 'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
bad = [l for l in s.splitlines() if re.search(r"tree=[^\"']*\[", l) and "%5B" not in l]
sys.exit(1 if bad else 0)
PYEOF
then
  echo "  ✓ tree 查询全部 %5B 编码"
else
  echo "  ✗ tree 查询存在未编码 []"; FAIL=1
fi
need "mktemp macOS 安全（XXXXXX 再 mv 后缀）" "grep -q 'mktemp /tmp/jenkins-batch.XXXXXX' $S"
need "gate-action.sh 显式 JOB_NAME（防 pipeline JOB_NAME 泄漏）" "grep -q 'JOB_NAME=\"\$CHILD_JOB\"' $S"
need "队列项 Location 主路径" "grep -q 'location:' $S"
need "lastBuild 回退必须按 PRODUCT 核对" "grep -q '疑似并行会话构建' $S"
need "等门循环有心跳" "grep -q 'beat_start \"子班 #' $S"
need "冷却有心跳" "grep -q 'sleep_with_beat' $S"
need "产品名校验（防手滑触发空班）" "grep -q '未知产品' $S"

echo "== DRY_RUN 行为 =="
TD=$(mktemp -d)
if BATCH_STATE_DIR="$TD" DRY_RUN=1 bash "$S" phase1 "auth,liuyao" static 0 >/dev/null 2>&1 \
   && [ "$(wc -l < "$TD/products.tsv" | tr -d ' ')" = "2" ] && [ -f "$TD/summary.txt" ]; then
  echo "  ✓ phase1 dry-run 状态文件（2 行 tsv + summary）"
else
  echo "  ✗ phase1 dry-run 状态文件"; FAIL=1
fi
if BATCH_STATE_DIR="$TD" DRY_RUN=1 bash "$S" phase3 0 >/dev/null 2>&1; then
  echo "  ✓ phase3 dry-run"
else
  echo "  ✗ phase3 dry-run"; FAIL=1
fi
if BATCH_STATE_DIR="$TD" DRY_RUN=1 bash "$S" abort-all >/dev/null 2>&1; then
  echo "  ✓ abort-all dry-run"
else
  echo "  ✗ abort-all dry-run"; FAIL=1
fi
if BATCH_STATE_DIR="$TD" DRY_RUN=1 bash "$S" phase1 "auth,nosuch" static 0 >/dev/null 2>&1; then
  echo "  ✗ 未知产品应报错退出"; FAIL=1
else
  echo "  ✓ 未知产品报错退出"
fi

echo "== 结果 =="
[ "$FAIL" = "0" ] && echo "ALL PASS" || echo "FAILED"
exit "$FAIL"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash scripts/jenkins/batch-release-test.sh`
Expected: 全部 ✗（batch-release.sh 不存在）

- [ ] **Step 3: 写 batch-release.sh 骨架（公共件 + main 分发）**

创建 `scripts/jenkins/batch-release.sh`：

```bash
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

main() {
  local cmd="${1:?用法: batch-release.sh phase1|phase3|abort-all}"
  case "$cmd" in
    phase1)    cmd_phase1 "${2:-}" "${3:-static}" "${4:-60}" ;;
    phase3)    cmd_phase3 "${2:-60}" ;;
    abort-all) cmd_abort_all ;;
    *) echo "未知子命令：$cmd（phase1|phase3|abort-all）"; exit 2 ;;
  esac
}
```

- [ ] **Step 4: 追加占位子命令让 main 可跑（Task 2/3 填实）**

在 `main()` 之前追加：

```bash
cmd_phase1() { echo "TODO-task2"; return 1; }
cmd_phase3() { echo "TODO-task3"; return 1; }
cmd_abort_all() { echo "TODO-task3"; return 1; }
```

并在文件末尾追加 `main "$@"` 与可执行位：

```bash
main "$@"
```

Run: `chmod +x scripts/jenkins/batch-release.sh`
Run: `bash scripts/jenkins/batch-release-test.sh`
Expected: needle 里 bash 语法/会话 cookie/strict=False/mktemp 全 ✓；行为测试 ✗（TODO 子命令 return 1）——部分通过即可，Task 2/3 补齐

- [ ] **Step 5: Commit**

```bash
git add scripts/jenkins/batch-release.sh scripts/jenkins/batch-release-test.sh
git commit -m "feat(release-all): 批量发布编排器骨架+守卫测试壳（公共件/心跳/状态约定）"
```

---

### Task 2: phase1——触发/等门/探活/资源门禁/冷却

**Files:**
- Modify: `scripts/jenkins/batch-release.sh`（替换 `cmd_phase1` 占位）

**Interfaces:**
- Consumes: Task 1 的 `session_init/crumb_header/beat/pending_count/child_state/tsv_path/tg`；仓库既有 `pipeline_resource_gate`（scripts/pipeline-stages.sh，需 `SSH_KEY_FILE`）。
- Produces: `child_trigger <product> <layer>`（stdout=子班号）、`child_wait_gate <build>`（0=到门）、`probe_preprod <product> <layer>`、`resource_gate`、`write_summary`；products.tsv 落盘。

- [ ] **Step 1: 写实现（替换 TODO-task2 占位）**

```bash
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
    beat_start "子班已受理（$product，队列排队中）"
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
    [ "$p" = "$product" ] || { echo "构建#$build PRODUCT=$p ≠ $product，疑似并行会话构建" >&2; return 1; }
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

probe_url() { # $1=url，3 次×10s
  local url="$1" try
  for try in 1 2 3; do
    if curl -sf --max-time 15 -o /dev/null "$url"; then return 0; fi
    sleep 10
  done
  return 1
}

probe_preprod() { # $1=product $2=layer；static=根 URL 200 / all=根 URL+API 探针 200
  local url="${PREPROD_URL[$1]}"
  probe_url "$url" || return 1
  if [ "$2" = "all" ]; then probe_url "${url%/}${API_PROBE[$1]:-/api/health}" || return 1; fi
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
  for p in "${products[@]}"; do
    if [ -z "${PREPROD_URL[$p]:-}" ]; then
      echo "未知产品：$p（合法：${ALL_PRODUCTS[*]}）" >&2; exit 2
    fi
  done
  local total=${#products[@]} idx=0 build probe note
  for p in "${products[@]}"; do
    idx=$((idx + 1))
    echo "━━━━━ [$idx/$total] $p（LAYER=$layer）━━━━━"
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$build" "$probe" "${PREPROD_URL[$p]}" "$note" >> "$tsv"
    if [ "$probe" = "ok" ]; then
      tg "📦 批量发布 [$idx/$total] $p：✅ preprod 就绪 ${PREPROD_URL[$p]}（班 #$build）"
    else
      tg "📦 批量发布 [$idx/$total] $p：❌ $note（批量门上会标注，继续下一产品）"
    fi
    if [ "$idx" -lt "$total" ]; then sleep_with_beat "$cooldown"; fi
  done
  write_summary
}
```

- [ ] **Step 2: 跑测试**

Run: `bash scripts/jenkins/batch-release-test.sh`
Expected: phase1 dry-run 两项 ✓（2 行 tsv + summary；未知产品报错）；phase3/abort-all 行为仍 ✗（Task 3 补）

- [ ] **Step 3: 手动真实验证（可选，触发前自查）**

Run: `bash -n scripts/jenkins/batch-release.sh && bash scripts/jenkins/batch-release-test.sh`
Expected: ALL PASS（除 phase3/abort-all 行为项）

- [ ] **Step 4: Commit**

```bash
git add scripts/jenkins/batch-release.sh scripts/jenkins/batch-release-test.sh
git commit -m "feat(release-all): phase1 逐产品触发+等门+探活+资源门禁+冷却（队列项防抢号/心跳/失败清单）"
```

---

### Task 3: phase3 代批停损 + abort-all 清理

**Files:**
- Modify: `scripts/jenkins/batch-release.sh`（替换 `cmd_phase3`/`cmd_abort_all` 占位）

**Interfaces:**
- Consumes: Task 1/2 全部公共函数；外部 `gate-action.sh`（必须 `JOB_NAME="$CHILD_JOB"` 前缀）。
- Produces: phase3 成功/停损语义（子班 SUCCESS=prod 就绪口径，见 Global Constraints 修正）；abort-all 幂等清理。

- [ ] **Step 1: 写实现（替换两个 TODO 占位）**

```bash
cmd_phase3() { # $1=cooldown；逐个代批 ✅ 产品，任一失败立即停损
  local cooldown="$1"
  local tsv; tsv=$(tsv_path)
  local p build probe url note state ok_count=0 dry
  dry="${DRY_RUN:-0}"
  while IFS=$'\t' read -r p build probe url note; do
    [ -n "$p" ] || continue
    if [ "$probe" != "ok" ]; then
      echo "⏭ 跳过 $p（preprod 未就绪：${note:-未验证}）"
      continue
    fi
    if [ "$dry" = "1" ]; then
      echo "[dry-run] 将代批 #$build $p → deploy_prod，随后守望子班完成"
      continue
    fi
    echo "━━━━━ 🚀 $p 部署 prod（代批班 #$build）━━━━━"
    if ! JOB_NAME="$CHILD_JOB" "$DIR/gate-action.sh" "$build" deploy_prod; then
      tg "🛑 批量发布中止：$p 代批失败（班 #$build）。已上 prod $ok_count 个；失败班与 -old 锚点见 Jenkins"
      echo "❌ $p 代批失败——停止后续产品（已发布内容不动，-old 锚点未动，可手工回滚）" >&2
      exit 1
    fi
    beat_start "子班 #$build（$p）prod 发布中"
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
      tg "🛑 批量发布中止：$p 子班 #$build 结束=$state（预期 SUCCESS）。已上 prod $ok_count 个；该产品 -old 锚点可回滚，后续产品未动"
      echo "❌ $p prod 发布失败（$state）——停止后续产品" >&2
      exit 1
    fi
    ok_count=$((ok_count + 1))
    tg "🚀 批量发布 [$p] prod 完成（累计 $ok_count）"
    sleep_with_beat "$cooldown"
  done < "$tsv"
  if [ "$dry" != "1" ]; then tg "✅ 批量发布全程完成：$ok_count 个产品已上 prod"; fi
  echo "✅ phase3 完成（$ok_count 个产品）"
}

cmd_abort_all() { # 幂等：只处理仍 pending 的子班门
  local tsv p build probe url note n=0
  tsv=$(tsv_path)
  if [ ! -f "$tsv" ]; then echo "无状态文件，无需清理"; return 0; fi
  while IFS=$'\t' read -r p build probe url note; do
    [ -n "$build" ] && [ "$build" != "0" ] || continue
    if [ "${DRY_RUN:-0}" = "1" ]; then echo "[dry-run] 将 abort 子班 #$build（$p）"; continue; fi
    if [ "$(pending_count "$build")" = "0" ]; then
      echo "ℹ️ 子班 #$build（$p）无 pending 门（已自行结束），跳过"
      continue
    fi
    if JOB_NAME="$CHILD_JOB" "$DIR/gate-action.sh" "$build" abort; then
      echo "🧹 子班 #$build（$p）已 abort"; n=$((n + 1))
    else
      echo "⚠️ 子班 #$build abort 失败（可能刚被处理），请人工核对"
    fi
  done < "$tsv"
  echo "清理完成：abort $n 个子班"
}
```

- [ ] **Step 2: 跑全量测试**

Run: `bash scripts/jenkins/batch-release-test.sh`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add scripts/jenkins/batch-release.sh scripts/jenkins/batch-release-test.sh
git commit -m "feat(release-all): phase3 代批停损（子班 SUCCESS 口径/-old 锚点提示）+ abort-all 幂等清理"
```

---

### Task 4: Jenkinsfile.batch 薄胶水

**Files:**
- Create: `jenkins/Jenkinsfile.batch`

**Interfaces:**
- Consumes: `scripts/jenkins/batch-release.sh`（Task 1-3）；凭据 `r4s-ssh-key`；状态文件 `.batch-state/summary.txt`。
- Produces: env.BATCH_ACTION（deploy_prod/abort）供 post 钩子判断。

- [ ] **Step 1: 写 Jenkinsfile.batch**

```groovy
// Jenkinsfile.batch — noda-release-all 全站批量发布编排
// spec: docs/superpowers/specs/2026-10-08-release-all-batch-deploy-design.md
// noda-apps 单产品管线零改动；本 job 是指挥家：触发/等门/批量门/代批/汇报。
// 用户硬要求：一切等待必须可见——心跳由 batch-release.sh 输出，本文件不加静默等待。
pipeline {
    agent any
    options {
        disableConcurrentBuilds()
        timestamps()
        timeout(time: 24, unit: 'HOURS')
    }
    parameters {
        string(name: 'PRODUCTS', defaultValue: '',
               description: '逗号分隔产品子集（空=全部 8 站：class,www,admin,liuyao,nearby,auth,comment,snagme）')
        choice(name: 'LAYER', choices: ['static', 'all'],
               description: 'static=8 站前端（默认）/ all=前后端一起（单趟显著更长）')
        string(name: 'COOLDOWN_SECONDS', defaultValue: '60',
               description: '产品间冷却秒数（r4s 单盘喘息窗口）')
    }
    stages {
        stage('Phase 1 逐产品构建+preprod') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'r4s-ssh-key', keyFileVariable: 'SSH_KEY_FILE')]) {
                    sh 'scripts/jenkins/batch-release.sh phase1 "${PRODUCTS}" "${LAYER}" "${COOLDOWN_SECONDS}"'
                }
            }
        }
        stage('Phase 2 批量审批门') {
            options { timeout(time: 6, unit: 'HOURS') }
            steps {
                script {
                    def sf = "${env.WORKSPACE}/.batch-state/summary.txt"
                    def summary = fileExists(sf) ? readFile(sf) : '(phase1 未产出状态文件)'
                    env.BATCH_ACTION = input(
                        message: """全站批量审批（LAYER=${params.LAYER}）——逐行验证 preprod 后决策：

${summary}

deploy_prod = 依次部署全部 ✅ 产品（❌ 自动跳过，失败不拦路）
abort = 中止批量并清理所有已到门的子班
⏱ 本门 6 小时超时（记 FAILURE）。单产品补发请用 noda-apps 单班。""",
                        parameters: [choice(name: 'ACTION', choices: ['deploy_prod', 'abort'],
                                            description: '批量决策')]
                    )
                }
            }
        }
        stage('Phase 3 依次部署 prod') {
            when { expression { env.BATCH_ACTION == 'deploy_prod' } }
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'r4s-ssh-key', keyFileVariable: 'SSH_KEY_FILE')]) {
                    sh 'scripts/jenkins/batch-release.sh phase3 "${COOLDOWN_SECONDS}"'
                }
            }
        }
        stage('清理全部子班') {
            when { expression { env.BATCH_ACTION == 'abort' } }
            steps {
                sh 'scripts/jenkins/batch-release.sh abort-all'
            }
        }
    }
    post {
        failure {
            script {
                def sf = "${env.WORKSPACE}/.batch-state/summary.txt"
                def summary = fileExists(sf) ? readFile(sf) : '(无状态文件)'
                echo "批量发布失败。状态：\n${summary}"
                sh 'scripts/jenkins/tg-notify.sh "🛑 noda-release-all #${BUILD_NUMBER} 失败——详情见 Jenkins 控制台"'
            }
        }
        aborted {
            // 用户中止/审批超时/构建超时：清理所有仍挂着的子班门
            sh 'scripts/jenkins/batch-release.sh abort-all || true'
        }
    }
}
```

- [ ] **Step 2: needle 自检 + 提交**

Run: `grep -c "disableConcurrentBuilds\|timeout(time: 6\|abort-all" jenkins/Jenkinsfile.batch`
Expected: ≥3

```bash
git add jenkins/Jenkinsfile.batch
git commit -m "feat(release-all): Jenkinsfile.batch 薄胶水（Phase1/批量门 6h/Phase3/abort 清理/双通道汇报）"
```

---

### Task 5: seed job + Script Console 创建

**Files:**
- Create: `scripts/jenkins/init.groovy.d/15-pipeline-job-noda-release-all.groovy`

**Interfaces:**
- Consumes: 13-pipeline-job-noda-apps.groovy 的 XML 结构（同 SCM、同凭据）；`jenkins/Jenkinsfile.batch`。
- Produces: Jenkins job `noda-release-all`（PRODUCTS/LAYER/COOLDOWN_SECONDS 参数化）。

- [ ] **Step 1: 写 seed 脚本**

```groovy
// Jenkins Pipeline 作业配置 - 全站批量发布编排（noda-release-all）
// 功能：创建/更新 Pipeline Job，从 noda-infra 仓库读取 jenkins/Jenkinsfile.batch
//       参数化：PRODUCTS 逗号分隔子集（空=全部 8 站）/ LAYER / COOLDOWN_SECONDS
// 执行时机：13-pipeline-job-noda-apps.groovy 之后（字母顺序 15）
// 更新策略：作业已存在则 updateByXml，否则 createProjectFromXML（幂等）
import jenkins.model.*

def instance = Jenkins.getInstance()
def jobName = 'noda-release-all'

def configXml = '''<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <description>全站批量发布编排（逐产品 preprod → 一个批量审批门 → 依次 prod；spec: docs/superpowers/specs/2026-10-08-release-all-batch-deploy-design.md）</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
        <hudson.model.StringParameterDefinition>
          <name>PRODUCTS</name>
          <description>逗号分隔产品子集（空=全部 8 站：class,www,admin,liuyao,nearby,auth,comment,snagme）</description>
          <defaultValue></defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
        <hudson.model.ChoiceParameterDefinition>
          <name>LAYER</name>
          <description>static=8 站前端（默认）/ all=前后端一起（单趟显著更长）</description>
          <choices class="java.util.Arrays$ArrayList">
            <a class="string-array">
              <string>static</string>
              <string>all</string>
            </a>
          </choices>
        </hudson.model.ChoiceParameterDefinition>
        <hudson.model.StringParameterDefinition>
          <name>COOLDOWN_SECONDS</name>
          <description>产品间冷却秒数（r4s 单盘喘息窗口，默认 60）</description>
          <defaultValue>60</defaultValue>
          <trim>true</trim>
        </hudson.model.StringParameterDefinition>
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition" plugin="workflow-cps">
    <scm class="hudson.plugins.git.GitSCM" plugin="git">
      <userRemoteConfigs>
        <hudson.plugins.git.UserRemoteConfig>
          <url>git@github.com:wangdianwen/noda-infra.git</url>
          <credentialsId>noda-infra-git-credentials</credentialsId>
        </hudson.plugins.git.UserRemoteConfig>
      </userRemoteConfigs>
      <branches>
        <hudson.plugins.git.BranchSpec>
          <name>*/main</name>
        </hudson.plugins.git.BranchSpec>
      </branches>
    </scm>
    <scriptPath>jenkins/Jenkinsfile.batch</scriptPath>
    <lightweight>false</lightweight>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>'''

def existingJob = instance.getItem(jobName)

if (existingJob != null) {
  existingJob.updateByXml(new javax.xml.transform.stream.StreamSource(new ByteArrayInputStream(configXml.getBytes('UTF-8'))))
  println "Pipeline job '${jobName}' updated to SCM mode."
} else {
  instance.createProjectFromXML(jobName, new ByteArrayInputStream(configXml.getBytes('UTF-8')))
  println "Pipeline job '${jobName}' created with SCM mode."
}

instance.save()
```

注意：XML 里 `<branches>` 必须在 `<userRemoteConfigs>` 之后、位于 `<scm>` 内（上面块中已含，誊写时保持 GitSCM 结构与 13 号 seed 完全一致：userRemoteConfigs → branches → gitTool 可省）。

- [ ] **Step 2: push 后经 Script Console 创建 job**

```bash
git add scripts/jenkins/init.groovy.d/15-pipeline-job-noda-release-all.groovy
git commit -m "feat(release-all): noda-release-all job seed（配置即代码，幂等创建/更新）"
git push   # CpsScmFlowDefinition 每次构建现检出，push 即生效
```

```bash
source scripts/jenkins/config/jenkins-admin.env
JAR=$(mktemp /tmp/jenkins-sd.XXXXXX) && mv "$JAR" "$JAR.jar" && JAR="$JAR.jar"
curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -c "$JAR" http://127.0.0.1:8080/login >/dev/null
CRUMB=$(curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -b "$JAR" http://127.0.0.1:8080/crumbIssuer/api/json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])')
curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -b "$JAR" -H "$CRUMB" -X POST http://127.0.0.1:8080/scriptText --data-urlencode "script@scripts/jenkins/init.groovy.d/15-pipeline-job-noda-release-all.groovy"
rm -f "$JAR"
```

Expected: 输出 `Pipeline job 'noda-release-all' created with SCM mode.`

- [ ] **Step 3: 验证 job 就位**

Run: `curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" "http://127.0.0.1:8080/job/noda-release-all/api/json?tree=name,color" `
Expected: `{"_class":"...WorkflowJob","name":"noda-release-all",...}`（HTTP 200）

---

### Task 6: 真实 spike——auth+liuyao 小子集全流程验收

**Files:** 无新文件（验收+修缺陷轮）

**Interfaces:**
- Consumes: Task 1-5 全部产出。

- [ ] **Step 1: 触发小子集批量班**

```bash
source scripts/jenkins/config/jenkins-admin.env
JAR=$(mktemp /tmp/jenkins-tr.XXXXXX) && mv "$JAR" "$JAR.jar" && JAR="$JAR.jar"
curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -c "$JAR" http://127.0.0.1:8080/login >/dev/null
CRUMB=$(curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -b "$JAR" http://127.0.0.1:8080/crumbIssuer/api/json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])')
curl -s -o /dev/null -w "trigger HTTP %{http_code}\n" -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" -b "$JAR" -H "$CRUMB" -X POST "http://127.0.0.1:8080/job/noda-release-all/buildWithParameters" --data-urlencode "PRODUCTS=auth,liuyao" --data-urlencode "LAYER=static" --data-urlencode "COOLDOWN_SECONDS=30"
rm -f "$JAR"
```

Expected: HTTP 201

- [ ] **Step 2: 盯 Phase 1（验证心跳/失败清单/TG）**

Run（每 60s 一次直到 Phase 2 门）: `curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASSWORD" "http://127.0.0.1:8080/job/noda-release-all/lastBuild/wfapi/describe" | python3 -m json.tool | grep -E '"name"|"status"'`
验收点：①console 有 [1/2] [2/2] 分节与 ⏳ 心跳行 ②两个子班 auth/liuyao 停在各自审批门 ③TG 收到 2 条 preprod 就绪 ④summary.txt 两行 ✅

- [ ] **Step 3: 批量门浏览器验证**

浏览器登录打开 `/job/noda-release-all/<N>/input/`：确认审批消息列出 2 个 preprod 链接+状态表；先测 `abort` 路径（点 ACTION=abort → Proceed）——验证「清理全部子班」stage 跑完、两个子班变 ABORTED、TG 无崩溃。
（故意先 abort：prod 零影响下验证中止路径；下一轮再验 deploy_prod）

- [ ] **Step 4: 第二轮验 deploy_prod 全链**

重新触发（同 Step 1），到批量门后用 `JOB_NAME=noda-release-all scripts/jenkins/gate-action.sh <N> deploy_prod` 放行。
验收点：①两个子班依次 deploy_prod ②phase3 心跳与「🚀 prod 完成」TG ③编排班 SUCCESS ④prod 站点实际可访问（浏览器抽查 auth/liuyao）⑤`-old` 锚点更新。

- [ ] **Step 5: 缺陷修复轮（如有）**

任何验收点失败 → 修 batch-release.sh / Jenkinsfile.batch → 重跑 `bash scripts/jenkins/batch-release-test.sh` ALL PASS → 重跑本轮对应步骤。

- [ ] **Step 6: 收尾提交 + 记忆沉淀**

```bash
git add -A && git commit -m "chore(release-all): spike 验收修复（auth+liuyao 子集全流程）" --allow-empty
git push
```

并向 hindsight noda-infra 库 retain：spike 实测时长、发现的问题、全量首跑建议（低峰窗口）。

---

## Self-Review 记录

- Spec 覆盖：批量单门（Task 4 Phase 2）/ 参数化子集+层（Task 4/5 参数）/ 管线内治（Task 2 resource_gate+冷却）/ 心跳可观测（Task 1 beat + Task 2 等门）/ 失败语义两阶段各异（Task 2 continue vs Task 3 停损）/ abort 清理（Task 3 + Task 4 post）——全覆盖。
- 唯一口径修正：prod 探活=子班 SUCCESS（Global Constraints 已声明，源于 prod 域名无集中维护）。
- 类型/命名一致性：`BATCH_STATE_DIR/products.tsv` 五列（product/build/probe/preprod_url/note）在 Task 1 定义、Task 2 写、Task 3 读，一致；`JOB_NAME="$CHILD_JOB"` 前缀在 Task 1 needle 与 Task 3 实现呼应。
