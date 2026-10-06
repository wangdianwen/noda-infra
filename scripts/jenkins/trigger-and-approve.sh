#!/usr/bin/env bash
# trigger-and-approve.sh — Jenkins noda-apps 发布触发 + 批准门自动化
#
# 背景：input 批准门的 HTML 表单 POST 恒 400（"This page expects a form submission"），
# 可靠路径是 Script Console 直接调 InputStepExecution.proceed。本脚本固化实战全流程：
#   crumb+cookie → buildWithParameters → 队列项等出队取自己的构建号 →
#   轮询 input 出现 → scriptText 批准 → 等待结果
#
# 2026-10-06：浏览器审批按钮已修复可用（Jenkins 2.580.1 原生提交带 json +
# simple-theme-plugin 注入 userContent/fix-input-json.js 兜底，真浏览器
# Proceed/Abort 三连测通过）；本脚本的 Script Console 批准仅服务 AUTO_APPROVE=1。
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
# 2026-10-05 ⑤ 批准门存在性判断改 wfapi/pendingInputActions（无 pending 返回
#   [] HTTP 200，干净布尔）——/input/ 页 HTML 正则抓执行 id 太脆：id 首字符可能
#   大写（A/C/E/F 约 1/3，#610/#611 同日双卡实证），批准走 Script Console 遍历
#   executions 本就不需要 id。
# ⑥ TG 通知/告警（tg-notify.sh，凭据 config/telegram.env）：审批门放行、构建
#   完成结果、卡死退出均推送；通知失败静默不阻塞发布。
# ⑦ AUTO_APPROVE（2026-10-06 起默认 0=守望人工审批：不批准，每 10 分钟 TG 提醒，
#   等人工处理；=1 恢复自动批准 deploy_prod）。人工审批两条路：
#   浏览器构建页选 ACTION 后点 Proceed（或 gate-action.sh 三选，等价）。
#
# 前提：Jenkins 跑在本机 :8080（2026-10-05 实测 useSecurity=True，匿名只读；
# 构建触发需 admin basic auth，凭据 config/jenkins-admin.env），crumb+session 仍必须。
# 用法：jenkins/trigger-and-approve.sh <PRODUCT> <LAYER> <DEPLOY_MODE>
#   例：AUTO_APPROVE=1 jenkins/trigger-and-approve.sh class api normal  # 显式恢复全自动
set -euo pipefail

PRODUCT="${1:?用法: $0 <PRODUCT> <LAYER> <DEPLOY_MODE>}"
DIR="$(cd "$(dirname "$0")" && pwd)"

# admin basic auth（2026-10-05：Jenkins 开启安全域后匿名 POST 一律 403/login 跳转）
source "$DIR/config/jenkins-admin.env"
AUTH=("-u" "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
LAYER="${2:-api}"
MODE="${3:-normal}"
AUTO_APPROVE="${AUTO_APPROVE:-0}"
JENKINS="${JENKINS_URL:-http://localhost:8080}"
JOB="noda-apps"
# macOS mktemp 模板 X 不在末尾时按字面量处理（残留同名文件后恒 "File exists"，
# 2026-10-07 #654 触发两连败实证）——先建无后缀临时文件再改后缀
JAR=$(mktemp /tmp/jenkins-ta.XXXXXX) && mv "$JAR" "$JAR.jar" && JAR="$JAR.jar"
HDR=$(mktemp /tmp/jenkins-ta.XXXXXX) && mv "$HDR" "$HDR.hdr" && HDR="$HDR.hdr"
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
[ "$HTTP" = "201" ] || { echo "触发失败 HTTP=$HTTP"; "$DIR/tg-notify.sh" "❌ Jenkins ${PRODUCT}/${LAYER}/${MODE} 触发失败 HTTP=${HTTP}" || true; exit 1; }
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
# 存在性判断用 wfapi（无 pending 返回 [] HTTP 200）；批准本身走 Script Console
# 遍历 executions，不需要 id——HTML 正则抓 id 当判据的旧法已废（⑤）
pending_count() {
  local pend
  pend=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/wfapi/pendingInputActions" || true)
  printf '%s' "$pend" | json_field 'len(d)' 2>/dev/null || echo 0
}

approve_gate() {
  [ "$(pending_count)" != "0" ] || return 1
  CRUMB=$(crumb_header)   # crumb 绑会话且有时效（实测 ~1h），批准前重新取
  curl -s --max-time 30 "${AUTH[@]}" -b "$JAR" -H "$CRUMB" -X POST "$JENKINS/scriptText" \
    --data-urlencode "script=
def j = Jenkins.instance.getItem(\"$JOB\")
def b = j.getBuildByNumber($BUILD)
def ia = b.getAction(org.jenkinsci.plugins.workflow.support.steps.input.InputAction.class)
ia.getExecutions().each { ex -> println(\"approving: \" + ex.getInput().getMessage()); ex.proceed([\"ACTION\": \"deploy_prod\"]) }
println(\"approved\")" | tail -1
}

APPROVED_TG=0   # 审批门放行只推一次
for i in $(seq 1 60); do
  STATE=$(curl -s --max-time 10 "${AUTH[@]}" -b "$JAR" \
    "$JENKINS/job/$JOB/$BUILD/api/json?tree=building,result" |
    json_field 'str(d["building"]).lower()+"/"+str(d["result"])' 2>/dev/null || echo "parse-error")
  case "$STATE" in
    false/SUCCESS) echo "build#$BUILD 完成: $STATE"; exit 0 ;;
    false/*)
      echo "build#$BUILD 完成: $STATE"
      "$DIR/tg-notify.sh" "❌ Jenkins #${BUILD} ${PRODUCT}/${LAYER}/${MODE} 结束：${STATE#false/}" || true
      exit 1 ;;
  esac
  if [ "$(pending_count)" != "0" ]; then
    if [ "$AUTO_APPROVE" = "1" ]; then
      OUT=$(approve_gate || true)
      [ -n "$OUT" ] && echo "$OUT"
      if [ "$APPROVED_TG" = "0" ] && [ "$(pending_count)" = "0" ]; then
        APPROVED_TG=1
        "$DIR/tg-notify.sh" "🤖 Jenkins #${BUILD} ${PRODUCT}/${LAYER}/${MODE} 审批门已自动放行 deploy_prod（AUTO_APPROVE=1）；需拦截请尽快到构建页 Stop" || true
      fi
    elif [ $((i % 20)) = 1 ]; then
      echo "⏸ #${BUILD} 等待人工审批（AUTO_APPROVE=0）"
      "$DIR/tg-notify.sh" "⏸ Jenkins #${BUILD} ${PRODUCT}/${LAYER}/${MODE} 等待人工审批（6h 超时）→ 浏览器构建页选 ACTION 点 Proceed，或 gate-action.sh ${BUILD} deploy_prod|rebuild_preprod|abort" || true
    fi
  fi
  sleep 30
done
echo "30 分钟未完成，退出（构建仍在后台跑，可手动查看）"
"$DIR/tg-notify.sh" "⏰ Jenkins #${BUILD} ${PRODUCT}/${LAYER}/${MODE} 守望 30 分钟未结束，脚本退出（构建仍后台运行）" || true
exit 2
