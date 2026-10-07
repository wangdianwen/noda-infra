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
need "代批走内联 Script Console（workspace 无 gate-action env 依赖）" "grep -q 'child_gate_action' $S && grep -q 'Jenkins.instance.getItem' $S"
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
