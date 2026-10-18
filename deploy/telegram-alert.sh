#!/bin/sh
# 用法: telegram-alert.sh "消息文本"（Zcode For Ben bot → 用户 DM）
MSG="${1:-zcode alert}"
ENVF=/root/.hermes/.env
TOKEN=$(cat /mnt/mmc1-4/System/Scripts/.tg-alert-token 2>/dev/null)
CHAT=$(grep "^TELEGRAM_HOME_CHANNEL=" "$ENVF" 2>/dev/null | cut -d= -f2)
[ -n "$CHAT" ] || CHAT=7909337470
[ -n "$TOKEN" ] && [ -n "$CHAT" ] && curl -s "https://api.telegram.org/bot$TOKEN/sendMessage" \
  --data-urlencode "chat_id=$CHAT" --data-urlencode "text=$MSG" -o /dev/null
