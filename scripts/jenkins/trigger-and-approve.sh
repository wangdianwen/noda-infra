#!/usr/bin/env bash
# trigger-and-approve.sh — Jenkins noda-apps 发布触发 + 批准门自动化
#
# 背景：input 批准门的 HTML 表单 POST 恒 400（"This page expects a form submission"），
# 可靠路径是 Script Console 直接调 InputStepExecution.proceed。本脚本固化实战全流程：
#   crumb+cookie → buildWithParameters → 队列项等出队取自己的构建号 →
#   轮询 input 出现 → scriptText 批准 → 等待结果
#
# 2026-10-04 加固（实战三坑，见 spec/ledger）：
#   ① 所有 GET 必须带 -b "$JAR"——匿名读会被 Jenkins 间歇性回 HTML 登录页，
#     python 在 char 0 炸 JSONDecodeError（触发成功但脚本死于批准轮询前）
#   ② 构建号从 buildWithParameters 的 Location 队列项等出队取得，不盯 lastBuild
#     （并行会话抢号坑；队列项按构造即本次请求，天然自识别）。队列项丢失时回退
#     lastBuild + 强制按 PRODUCT 参数核对，参数不符即退出
#   ③ JSON 解析一律 strict=False——并行会话构建参数含未转义控制字符会炸严格解析
#   ④ tree 查询的 [] 一律 URL 编码 %5B/%5D（zsh glob 坑）
#
# 前提：Jenkins 跑在本机 :8080（2026-10-05 实测 useSecurity=True，匿名只读；
# 构建触发需 admin basic auth，凭据 config/jenkins-admin.env），crumb+session 仍必须。
# 用法：jenkins/trigger-and-approve.sh <PRODUCT> <LAYER> <DEPLOY_MODE>
#   例：jenkins/trigger-and-approve.sh class api normal
set -euo pipefail

PRODUCT="${1:?用法: $0 <PRODUCT> <LAYER> <DEPLOY_MODE>}"

# admin basic auth（2026-10-05：Jenkins 开启安全域后匿名 POST 一律 403/login 跳转）
source "$(dirname "$0")/config/jenkins-admin.env"
AUTH=("-u" "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
LAYER="${2:-api}"
MODE="${3:-normal}"
JENKINS="${JENKINS_URL:-http://localhost:8080}"
JOB="noda-apps"
JAR=$(mktemp /tmp/jenkins-ta.XXXXXX.jar)
HDR=$(mktemp /tmp/jenkins-ta.XXXXXX.hdr)
trap 'rm -f "$JAR" "$HDR"' EXIT

# json_field EXPR：stdin 收 JSON，strict=False 容忍控制字符，EXPR 在 d 上求值。
json_field() {
  python3 -c '
import sys, json
d = json.load(sys.stdin, strict=False)
print(eval(sys.argv[1]))' "$1"
}

crumb_header() {
  curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$JENKINS/crumbIssuer/api/json" |
    json_field 'd["crumbRequestField"]+": "+d["crumb"]'
}

# 1. 会话 + crumb
curl -s --max-time 10 "${AUTH[@]}" -c "$JAR" "$JENKINS/login" >/dev/null
CRUMB=$(crumb_header)

# 2. 触发：Location 头 = 我们的队列项（出队后即本次请求的构建号）
HTTP=$(curl -s "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST \
  "$JENKINS/job/$JOB/buildWithParameters" \
  --data "PRODUCT=$PRODUCT" --data "LAYER=$LAYER" --data "DEPLOY_MODE=$MODE" \
  -D "$HDR" -w '%{http_code}' -o /dev/null)
[ "$HTTP" = "201" ] || { echo "触发失败 HTTP=$HTTP"; exit 1; }
QITEM=$(grep -i '^location:' "$HDR" | tail -1 | tr -d '\r' | awk '{print $2}' | sed 's:/*$::')
[ -n "$QITEM" ] && [ "$QITEM" != "/" ] || { echo "未取得队列项 Location，请手动核对队列"; exit 1; }

# 3. 等出队拿自己的构建号（最长 10 分钟；执行器被并行会话占着时在此等）
BUILD=""
for i in $(seq 1 60); do
  OUT=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$QITEM/api/json" || true)
  if [ -n "$OUT" ]; then
    N=$(printf '%s' "$OUT" | json_field '(d.get("executable") or {}).get("number")' 2>/dev/null || true)
    if [ -n "$N" ] && [ "$N" != "None" ]; then BUILD=$N; break; fi
  fi
  sleep 10
done
if [ -z "$BUILD" ]; then
  echo "⚠️ 队列项 10 分钟未出队，回退 lastBuild 并按 PRODUCT 参数核对"
  BUILD=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/api/json?tree=lastBuild%5Bnumber%5D" | json_field 'd["lastBuild"]["number"]')
  P=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/api/json?tree=actions%5Bparameters%5Bname,value%5D%5D" |
    json_field '"|".join(p["value"] for a in d["actions"] for p in a.get("parameters", []) if p["name"] == "PRODUCT")' 2>/dev/null || echo "?")
  [ "$P" = "$PRODUCT" ] || { echo "构建#$BUILD PRODUCT=$P ≠ ${PRODUCT}，疑似并行会话构建，退出"; exit 1; }
fi
echo "build#$BUILD 已触发（PRODUCT=$PRODUCT LAYER=$LAYER MODE=${MODE}）"

# 4. 轮询批准门（最长 30 分钟；preprod 验证通过后才会出 input）
approve_gate() {
  local id
  id=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$JENKINS/job/$JOB/$BUILD/input/" |
    grep -oE '[a-f0-9]{32}/submit' | head -1 | cut -d/ -f1)
  [ -n "$id" ] || return 1
  CRUMB=$(crumb_header)   # crumb 绑会话且有时效（实测 ~1h），批准前重新取
  curl -s --max-time 30 "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST "$JENKINS/scriptText" \
    --data-urlencode "script=
def j = Jenkins.instance.getItem(\"$JOB\")
def b = j.getBuildByNumber($BUILD)
def ia = b.getAction(org.jenkinsci.plugins.workflow.support.steps.input.InputAction.class)
ia.getExecutions().each { ex -> println(\"approving: \" + ex.getInput().getMessage()); ex.proceed([\"ACTION\": \"deploy_prod\"]) }
println(\"approved\")" | tail -1
}

for i in $(seq 1 60); do
  STATE=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/api/json?tree=building,result" |
    json_field 'str(d["building"]).lower()+"/"+str(d["result"])' 2>/dev/null || echo "parse-error")
  case "$STATE" in
    false/*) echo "build#$BUILD 完成: $STATE"; exit 0 ;;
  esac
  OUT=$(approve_gate || true)
  [ -n "$OUT" ] && echo "$OUT"
  sleep 30
done
echo "30 分钟未完成，退出（构建仍在后台跑，可手动查看）"; exit 2
