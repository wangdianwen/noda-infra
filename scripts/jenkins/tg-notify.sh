#!/usr/bin/env bash
# tg-notify.sh — Jenkins 发布脚本共用的 Telegram 通知（fire-and-forget）
#
# 设计约束：通知失败绝不阻塞发布流程——任何错误静默退出（exit 0），
# 调用方无须（也不应）检查返回值。
# 凭据：config/telegram.env（TG_BOT_TOKEN / TG_CHAT_ID，已 gitignore；
# 2026-10-05 自 r4s /mnt/mmc1-4/System/Scripts/.tg-alert-token 同步）。
# 用法：tg-notify.sh "消息文本"（支持多行；空消息直接跳过）
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MSG="${1:-}"
[ -n "$MSG" ] || exit 0
# shellcheck disable=SC1091
[ -f "$DIR/config/telegram.env" ] && . "$DIR/config/telegram.env"
[ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || exit 0

curl -s --max-time 10 "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TG_CHAT_ID}" \
  --data-urlencode "text=${MSG}" >/dev/null 2>&1
exit 0
