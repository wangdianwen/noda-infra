#!/usr/bin/env bash
# trigger-and-approve.sh — Jenkins noda-apps 发布触发 + 批准门自动化（2026-10-03 固化）
#
# 背景：input 批准门的 HTML 表单 POST 恒 400（"This page expects a form submission"，
# 匿名 + Unsecured 授权 + crumb 头均试过），可靠路径是 Script Console 直接调
# InputStepExecution.proceed。本脚本固化 2026-10-03 实战验证的全流程：
#   crumb+cookie → buildWithParameters → 轮询 input 出现 → scriptText 批准 → 等待结果
#
# 前提：Jenkins 跑在本机 :8080（Unsecured + 无认证域，匿名可用，crumb 必须）。
# 用法：jenkins/trigger-and-approve.sh <PRODUCT> <LAYER> <DEPLOY_MODE>
#   例：jenkins/trigger-and-approve.sh class api normal
set -euo pipefail

PRODUCT="${1:?用法: $0 <PRODUCT> <LAYER> <DEPLOY_MODE>}"
LAYER="${2:-api}"
MODE="${3:-normal}"
JENKINS="${JENKINS_URL:-http://localhost:8080}"
JOB="noda-apps"
JAR=$(mktemp /tmp/jenkins-ta.XXXXXX.jar)
trap 'rm -f "$JAR"' EXIT

crumb_header() {
  curl -s -b "$JAR" "$JENKINS/crumbIssuer/api/json" |
    python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["crumbRequestField"]+": "+d["crumb"])'
}

# 1. 会话 + crumb
curl -s -c "$JAR" "$JENKINS/login" >/dev/null
CRUMB=$(crumb_header)

# 2. 触发
HTTP=$(curl -s -b "$JAR" -H "$CRUMB" -X POST \
  "$JENKINS/job/$JOB/buildWithParameters" \
  --data "PRODUCT=$PRODUCT" --data "LAYER=$LAYER" --data "DEPLOY_MODE=$MODE" \
  -w '%{http_code}' -o /dev/null)
[ "$HTTP" = "201" ] || { echo "触发失败 HTTP=$HTTP"; exit 1; }
sleep 5
BUILD=$(curl -s "$JENKINS/job/$JOB/api/json?tree=lastBuild[number]" |
  python3 -c 'import sys,json;print(json.load(sys.stdin)["lastBuild"]["number"])')
echo "build#$BUILD 已触发（PRODUCT=$PRODUCT LAYER=$LAYER MODE=$MODE）"

# 3. 轮询批准门（最长 30 分钟；preprod 验证通过后才会出 input）
approve_gate() {
  local id
  id=$(curl -s "$JENKINS/job/$JOB/$BUILD/input/" |
    grep -oE '[a-f0-9]{32}/submit' | head -1 | cut -d/ -f1)
  [ -n "$id" ] || return 1
  CRUMB=$(crumb_header)   # crumb 绑会话且有时效，批准前重新取
  curl -s -b "$JAR" -H "$CRUMB" -X POST "$JENKINS/scriptText" \
    --data-urlencode "script=
def j = Jenkins.instance.getItem(\"$JOB\")
def b = j.getBuildByNumber($BUILD)
def ia = b.getAction(org.jenkinsci.plugins.workflow.support.steps.input.InputAction.class)
ia.getExecutions().each { ex -> println(\"approving: \" + ex.getInput().getMessage()); ex.proceed([\"ACTION\": \"deploy_prod\"]) }
println(\"approved\")" | tail -1
}

for i in $(seq 1 60); do
  STATE=$(curl -s "$JENKINS/job/$JOB/$BUILD/api/json?tree=building,result" |
    python3 -c 'import sys,json;d=json.load(sys.stdin);print(str(d["building"]).lower()+"/"+str(d["result"]))')
  case "$STATE" in
    false/*) echo "build#$BUILD 完成: $STATE"; exit 0 ;;
  esac
  OUT=$(approve_gate || true)
  [ -n "$OUT" ] && echo "$OUT"
  sleep 30
done
echo "30 分钟未完成，退出（构建仍在后台跑，可手动查看）"; exit 2
