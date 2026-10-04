#!/usr/bin/env bash
# trigger-and-approve-test.sh — trigger-and-approve.sh 的守卫测试（needle + 行为）
# 背景：2026-10-04 实战三坑回归锁——①GET 漏会话 cookie 匿名读间歇性回 HTML；
# ②lastBuild 抢号；③控制字符炸严格 JSON 解析；④zsh glob 吃 []
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
S="$DIR/trigger-and-approve.sh"
FAIL=0
need() { # need <描述> <命令>
  if eval "$2" >/dev/null 2>&1; then echo "  ✓ $1"; else echo "  ✗ $1"; FAIL=1; fi
}

echo "== needle 守卫 =="
need "bash 语法" "bash -n $S"
# ① 所有 curl 必须带会话（-b 存 cookie；-c 建会话的 login 那条除外）
need "全部 curl 带会话 cookie" "! grep -nE 'curl -s' $S | grep -vE -- '-[bc] \"\\\$JAR\"'"
# ② lastBuild 只允许出现在回退分支，且回退必须按 PRODUCT 核对参数
need "lastBuild 仅回退分支" "grep -q '回退 lastBuild 并按 PRODUCT 参数核对' $S"
need "回退路径强制参数核对" "grep -q '\\[ \"\\\$P\" = \"\\\$PRODUCT\" \\]' $S"
need "主路径用队列项 Location" "grep -q \"location:\" $S && grep -q 'QITEM/api/json' $S"
# ③ JSON 解析必须 strict=False
need "JSON 解析 strict=False" "grep -q 'json.load(sys.stdin, strict=False)' $S"
# ④ tree 查询不得出现未编码的 []（zsh glob）
# ④ tree 查询不得出现未编码的 []（zsh glob）——bash 引号内嵌 [^"'] 易碎，用 python 断言
# ④ tree 查询不得出现未编码的 []（zsh glob）
if python3 - "$S" << 'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
bad = [l for l in s.splitlines() if re.search(r"tree=[^\"']*\[", l) and "%5B" not in l]
sys.exit(1 if bad else 0)
PYEOF
then echo "  ✓ tree 查询括号已 URL 编码"; else echo "  ✗ tree 查询括号已 URL 编码"; FAIL=1; fi
need "无危险 InputAction 类路径" "! grep -q 'cps.actions.InputAction' $S"
need "InputAction 正确类路径" "grep -q 'workflow.support.steps.input.InputAction' $S"
need "批准前刷新 crumb" "grep -q '批准前重新取' $S"
# ⑥ 批准门存在性判断走 wfapi（#610/#611 同日双卡：HTML 抓 id 对大写开头 id 恒失配）
need "存在性判断用 wfapi pendingInputActions" "grep -q 'wfapi/pendingInputActions' $S"
need "HTML 抓 id 旧法已移除" "! grep -qE 'grep -oE .\[a-zA-Z0-9\].*submit' $S"
# ⑦ AUTO_APPROVE 开关与 TG 通知挂钩（卡死/失败必须有人知道）
need "AUTO_APPROVE 默认开" "grep -q 'AUTO_APPROVE:-1' $S"
need "TG 通知挂钩≥3 处" "[ \$(grep -c 'tg-notify.sh' $S) -ge 3 ]"
# ⑤ macOS bash 3.2 会把紧跟 $VAR 的多字节字符并进变量名（实弹抓过：$MODE）→ unbound）
if python3 - "$S" << 'PYEOF'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
bad = re.findall(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]", s)
if bad:
    print("    bad:", bad)
sys.exit(1 if bad else 0)
PYEOF
then echo "  ✓ 无 \$VAR 紧跟非 ASCII（bash 3.2 变量名吞噬坑）"; else echo "  ✗ \$VAR 紧跟非 ASCII"; FAIL=1; fi

echo "== json_field 行为（strict=False 与队列项取号） =="
# 与脚本内 json_field 同款 snippet（改动须双向同步）
PY='
import sys, json
d = json.load(sys.stdin, strict=False)
print(eval(sys.argv[1]))'
P_CTRL=$'{"lastBuild":{"number":538,"why":"queued-ctrl\x01char"}}'
need "控制字符载荷 strict=False 可析" "printf '%s' \"\$P_CTRL\" | python3 -c \"\$PY\" 'd[\"lastBuild\"][\"number\"]' 2>/dev/null | grep -q 538"
need "严格解析对同载荷必炸（坑仍在的证明）" "! printf '%s' \"\$P_CTRL\" | python3 -c 'import sys,json;json.load(sys.stdin)' 2>/dev/null"
P_Q='{"executable":{"number":539,"url":"http://x/job/noda-apps/539/"},"why":"awaiting"}'
need "队列项 executable 取号" "printf '%s' \"\$P_Q\" | python3 -c \"\$PY\" '(d.get(\"executable\") or {}).get(\"number\")' 2>/dev/null | grep -q 539"
P_NONE='{"executable":null,"why":"pending"}'
need "未出队返回 None 可识别" "printf '%s' \"\$P_NONE\" | python3 -c \"\$PY\" '(d.get(\"executable\") or {}).get(\"number\")' 2>/dev/null | grep -q None"

echo "== gate-action.sh 守卫（人工三选唯一可用入口） =="
G="$DIR/gate-action.sh"
need "gate-action bash 语法" "bash -n $G"
need "gate-action 三选项校验" "grep -q 'deploy_prod|rebuild_preprod|abort' $G"
need "gate-action 全部 curl 带会话 cookie" "! grep -nE 'curl -s' $G | grep -vE -- '-[bc] \"\\\$JAR\"'"
need "gate-action InputAction 正确类路径" "grep -q 'workflow.support.steps.input.InputAction' $G"
need "gate-action 存在性判断用 wfapi" "grep -q 'wfapi/pendingInputActions' $G"

echo "== 活体冒烟（只读） =="
if curl -s --max-time 5 "http://localhost:8080/api/json" >/dev/null 2>&1; then
  need "本机 Jenkins 可达且 lastCompletedBuild 可按新法解析" \
    "curl -s --max-time 5 http://localhost:8080/job/noda-apps/lastCompletedBuild/api/json?tree=number,result | python3 -c \"\$PY\" 'str(d[\"number\"])+\"/\"+str(d[\"result\"])' 2>/dev/null | grep -qE '[0-9]+/(SUCCESS|FAILURE|UNSTABLE|ABORTED)'"
else
  echo "  - Jenkins 不可达，跳过活体冒烟"
fi

[ "$FAIL" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILED"; exit 1; }
