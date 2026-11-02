#!/usr/bin/env bash
# hindsight-llm-watchdog.sh — LLM 配额耗尽自动降级 deepseek（2026-11-01 用户定）
#
# 原理：体验模型（zai/glm-5.3-flash coding plan）额度耗尽时，hindsight 日志出现
# 429/1310/defer 模式（2026-10-30 判例：retain 全部被 defer）。本脚本自上次检查点
# 起扫 docker logs，命中即切 env.deepseek 重建容器 + TG 报用户；未命中只推进检查点。
# 手动恢复体验模型：切回 env.zai 后跑 hindsight-recreate.sh rebuild。
set -euo pipefail

STATE="$HOME/.config/hindsight/.watchdog-since"
LLM_ENV_DIR="$HOME/.config/hindsight"
NOW=$(date +%s)
LAST=$(cat "$STATE" 2>/dev/null || echo $((NOW - 21600)))
echo "$NOW" > "$STATE"

LOGS=$(docker logs hindsight --since "$((NOW - LAST))"s 2>&1 || true)
# 精确模式：只认配额类失败（排除 cgroup quota=none 类启动噪音与泛 defer）
# 2026-11-02 补 402/insufficient_balance：DeepSeek 余额耗尽报 402，原模式不命中导致卡死降级位无法自愈
HITS=$(printf '%s' "$LOGS" | grep -ciE 'status[ =:]?429|error.{0,20}429|code[ =:]?1310|rate.?limit|insufficient_quota|quota.{0,20}(exceed|exhaust|limit)|(exceed|exhaust).{0,20}quota|insufficient_balance|HTTP[ =:]?402|error code: 402' || true)

if [ "$HITS" -eq 0 ]; then
  echo "✓ LLM 正常（近 $(( (NOW-LAST)/3600 ))h 无配额失败）"
  exit 0
fi

CUR=$(docker inspect hindsight --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^HINDSIGHT_API_LLM_PROVIDER=' | cut -d= -f2)
# 优先级自愈（2026-11-01 用户定：zai 正常即回 zai，deepseek 只是降级位）
if [ "$CUR" = "deepseek" ]; then
  ZKEY=$(grep '^HINDSIGHT_API_LLM_API_KEY=' "$LLM_ENV_DIR/env.zai" 2>/dev/null | cut -d= -f2)
  if [ -n "$ZKEY" ] && curl -s --max-time 20 https://api.z.ai/api/anthropic/v1/messages \
      -H "Authorization: Bearer $ZKEY" -H "anthropic-version: 2023-06-01" \
      -H "content-type: application/json" \
      -d '{"model":"glm-5.3-flash","max_tokens":8,"messages":[{"role":"user","content":"OK"}]}' \
      | grep -q '"content"'; then
    HINDSIGHT_LLM_ENV_FILE="$LLM_ENV_DIR/env.zai" \
      "$(dirname "$0")/hindsight-recreate.sh" rebuild >/dev/null 2>&1 || true
    echo "✓ zai 已恢复 → 自动切回体验模型（优先级自愈）"
    exit 0
  fi
  echo "ℹ️ 日志有 ${HITS} 条失败但已在 deepseek，zai 探测仍失败，维持降级"
  exit 0
fi

echo "⚠️ 命中 ${HITS} 条配额失败模式 → 降级 deepseek"
HINDSIGHT_LLM_ENV_FILE="$LLM_ENV_DIR/env.deepseek" \
  "$(dirname "$0")/hindsight-recreate.sh" rebuild >/dev/null 2>&1 || true
curl -s -X POST "https://api.telegram.org/bot$(doppler secrets get --project noda --config prd TELEGRAM_BOT_TOKEN --plain 2>/dev/null | tr -d '\n')/sendMessage" \
  -d chat_id="$(doppler secrets get --project noda --config prd TELEGRAM_CHAT_ID --plain 2>/dev/null | tr -d '\n')" \
  -d text="⚠️ hindsight LLM 已自动降级 deepseek（体验模型配额耗尽，日志命中 ${HITS} 条失败）。额度重置后手动切回：HINDSIGHT_LLM_ENV_FILE=~/.config/hindsight/env.zai ~/project/noda-infra/scripts/hindsight-recreate.sh rebuild" \
  >/dev/null 2>&1 || true
echo "✓ 已降级 deepseek 并 TG 报用户"
