#!/usr/bin/env bash
# gate-action.sh — 人工审批门三选项的唯一可用入口（浏览器 Proceed/Abort 恒 400）
#
# 背景（2026-10-05 根因，见仓库 ledger 与 jenkins-err.log #225→#536）：
#   input 步骤的表单提交缺 Stapler 必需的 json 参数 → 浏览器点 Proceed/Abort
#   一律 400 "This page expects a form submission"（Jenkins 上游 UI 缺陷）。
#   trigger-and-approve.sh 只会自动批 deploy_prod，rebuild_preprod / abort
#   此前无任何可用路径——本脚本补齐：与 trigger-and-approve 同款 Script Console
#   路径（crumb+会话 → wfapi 判 pending → ex.proceed/abort）。
# 用法：gate-action.sh <BUILD_NUMBER> <deploy_prod|rebuild_preprod|abort>
# 例：  gate-action.sh 611 rebuild_preprod
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="${1:?用法: $0 <BUILD_NUMBER> <deploy_prod|rebuild_preprod|abort>}"
ACTION="${2:?用法: $0 <BUILD_NUMBER> <deploy_prod|rebuild_preprod|abort>}"
case "$ACTION" in
  deploy_prod|rebuild_preprod|abort) ;;
  *) echo "非法 ACTION：$ACTION（只允许 deploy_prod / rebuild_preprod / abort）"; exit 1 ;;
esac
JOB="${JOB_NAME:-noda-apps}"
JENKINS="${JENKINS_URL:-http://localhost:8080}"

# admin basic auth（凭据 config/jenkins-admin.env，已 gitignore）
# shellcheck disable=SC1091
source "$DIR/config/jenkins-admin.env"
AUTH=("-u" "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
JAR=$(mktemp /tmp/jenkins-ga.XXXXXX.jar)
trap 'rm -f "$JAR"' EXIT

# json_field EXPR：与 trigger-and-approve.sh 同款（strict=False 容忍控制字符）
json_field() {
  python3 -c '
import sys, json
d = json.load(sys.stdin, strict=False)
print(eval(sys.argv[1]))' "$1"
}

# 1. 会话 + crumb（POST 必须，2026-10-05 useSecurity 后匿名 POST 一律 403）
curl -s --max-time 10 "${AUTH[@]}" -c "$JAR" "$JENKINS/login" >/dev/null
CRUMB=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$JENKINS/crumbIssuer/api/json" |
  json_field 'd["crumbRequestField"]+": "+d["crumb"]')

# 2. 确认有 pending input（wfapi：无 pending 返回 [] HTTP 200，干净的布尔）
PEND=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
  "$JENKINS/job/$JOB/$BUILD/wfapi/pendingInputActions" || true)
N=$(printf '%s' "$PEND" | json_field 'len(d)' 2>/dev/null || echo 0)
if [ "$N" = "0" ]; then
  echo "#$BUILD 当前没有 pending 的审批门（已批准过 / 尚未走到 / 构建不存在）"
  exit 1
fi
printf '%s' "$PEND" | json_field '"\n".join("pending: "+i.get("message","")[:120] for i in d)' 2>/dev/null || true

# 3. Script Console 执行（deploy_prod/rebuild_preprod 走 proceed，abort 走 ex.abort()）
GROOVY_ACTION='abort'
GROOVY_VALUE='null'
if [ "$ACTION" != "abort" ]; then
  GROOVY_ACTION='proceed'
  GROOVY_VALUE="[\"ACTION\": \"$ACTION\"]"
fi
curl -s --max-time 30 "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST "$JENKINS/scriptText" \
  --data-urlencode "script=
def j = Jenkins.instance.getItem(\"$JOB\")
def b = j.getBuildByNumber($BUILD)
def ia = b.getAction(org.jenkinsci.plugins.workflow.support.steps.input.InputAction.class)
if (ia == null) { println(\"no-input-action\"); return }
ia.getExecutions().each { ex ->
  println(\"applying $ACTION: \" + ex.getInput().getMessage())
  try { if (\"$GROOVY_ACTION\" == \"proceed\") { ex.proceed($GROOVY_VALUE) } else { ex.abort() } }
  catch (e) { println(\"failed: \" + e.message) }
}
println(\"done\")" | tail -5

# 4. 复核：pending 应当清零
sleep 2
PEND2=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
  "$JENKINS/job/$JOB/$BUILD/wfapi/pendingInputActions" || true)
N2=$(printf '%s' "$PEND2" | json_field 'len(d)' 2>/dev/null || echo "?")
if [ "$N2" = "0" ]; then
  echo "✅ #${BUILD} 审批门已按 ${ACTION} 处理"
else
  echo "⚠️ 复核仍有 ${N2} 个 pending，请到构建页核对"
  exit 1
fi
