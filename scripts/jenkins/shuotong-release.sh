#!/usr/bin/env bash
# shuotong-release.sh — shuotong-wang job 首发（触发+自动批准+盯结果）
# 复用 trigger-and-approve.sh 实战机制（crumb+cookie、队列项取号、scriptText 批准）
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/config/jenkins-admin.env"
AUTH=("-u" "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
MODE="${1:-normal}"
JOB="shuotong-wang"
JENKINS="${JENKINS_URL:-http://localhost:8080}"
JAR=$(mktemp /tmp/shr.XXXXXX) && mv "$JAR" "$JAR.jar" && JAR="$JAR.jar"
HDR=$(mktemp /tmp/shr.XXXXXX) && mv "$HDR" "$HDR.hdr" && HDR="$HDR.hdr"
trap 'rm -f "$JAR" "$HDR"' EXIT

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

curl -s --max-time 10 "${AUTH[@]}" -c "$JAR" "$JENKINS/login" >/dev/null
CRUMB=$(crumb_header)

HTTP=$(curl -s "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST \
  "$JENKINS/job/$JOB/buildWithParameters" \
  --data "DEPLOY_MODE=$MODE" \
  -D "$HDR" -w '%{http_code}' -o /dev/null)
[ "$HTTP" = "201" ] || { echo "触发失败 HTTP=$HTTP"; exit 1; }
QITEM=$(grep -i '^location:' "$HDR" | tail -1 | tr -d '\r' | awk '{print $2}' | sed 's:/*$::')
[ -n "$QITEM" ] && [ "$QITEM" != "/" ] || { echo "未取得队列项 Location"; exit 1; }

BUILD=""
for i in $(seq 1 60); do
  OUT=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" "$QITEM/api/json" || true)
  if [ -n "$OUT" ]; then
    N=$(printf '%s' "$OUT" | json_field '(d.get("executable") or {}).get("number")' 2>/dev/null || true)
    if [ -n "$N" ] && [ "$N" != "None" ]; then BUILD=$N; break; fi
  fi
  sleep 10
done
[ -n "$BUILD" ] || { echo "队列项 10 分钟未出队"; exit 1; }
echo "shuotong-wang build#$BUILD 已触发 (MODE=${MODE})"

pending_count() {
  local pend
  pend=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/wfapi/pendingInputActions" || true)
  printf '%s' "$pend" | json_field 'len(d)' 2>/dev/null || echo 0
}

approve_gate() {
  [ "$(pending_count)" != "0" ] || return 1
  CRUMB=$(crumb_header)
  curl -s --max-time 30 "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST "$JENKINS/scriptText" \
    --data-urlencode "script=
def j = Jenkins.instance.getItem(\"$JOB\")
def b = j.getBuildByNumber($BUILD)
def ia = b.getAction(org.jenkinsci.plugins.workflow.support.steps.input.InputAction.class)
ia.getExecutions().each { ex -> println(\"approving: \" + ex.getInput().getMessage()); ex.proceed([\"ACTION\": \"deploy_prod\"]) }
println(\"approved\")" | tail -1
}

for i in $(seq 1 90); do
  STATE=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/api/json?tree=building,result" |
    json_field 'str(d["building"]).lower()+"/"+str(d["result"])' 2>/dev/null || echo "parse-error")
  case "$STATE" in
    false/SUCCESS) echo "build#$BUILD 完成: $STATE"; exit 0 ;;
    false/*) echo "build#$BUILD 完成: $STATE"; exit 1 ;;
  esac
  if [ "$((i % 3))" = "0" ]; then approve_gate || true; fi
  sleep 20
done
echo "30 分钟未完成，退出"
exit 1
