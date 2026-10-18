#!/bin/sh
# B2 配额 TG 守卫（2026-10-18）：容器内 b2-quota-monitor 的邮件告警曾因 env 空串静默丢失
# （9-30~10-18），本守卫在 r4s 宿主侧兜底——读容器日志卷里的 b2-quota.log 最新一笔，
# 用量百分比「变化才发」TG（防 61-65% 平台期每日刷屏）；查询失败行也变化才报。
# 由宿主 crontab 每天 05:20 调用（容器 05:10 监控之后）。TG 走 telegram-alert.sh。
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh
QLOG=/opt/noda/noda-infra/docker/volumes/logs/b2-quota.log
STATE=/mnt/mmc1-4/System/Scripts/.b2-quota-tg-last
LOG=/var/log/noda-b2quota-guard.log

LAST=$(grep -E "用量: [0-9]+ / [0-9]+ bytes|用量查询失败" "$QLOG" 2>/dev/null | tail -1)
[ -z "$LAST" ] && exit 0

# 失败行：报「B2 用量查询失败」
if echo "$LAST" | grep -q "查询失败"; then
  CUR="FAIL"
  MSG="❌ B2 配额监控查询失败（b2-quota.log 最新一笔异常，桶状态未知），请人工核查 noda-ops 容器。"
else
  PCT=$(echo "$LAST" | sed -n "s/.*bytes = \([0-9]*\)%.*/\1/p")
  BYTES=$(echo "$LAST" | sed -n "s/.*用量: \([0-9]*\) .*/\1/p")
  GB=$((BYTES / 1073741824)); MB=$(( (BYTES % 1073741824) * 100 / 1073741824 ))
  CUR="$PCT"
  if [ "$PCT" -ge 60 ]; then
    MSG="❌ B2 桶用量 ${PCT}%（约 ${GB}.${MB} GB / 10GB 免费额度，严重线 60%）。nearby 已挪百度云；若持续上涨查 backups/filesystem/ 前缀与 b2-quota.log 分前缀明细。"
  elif [ "$PCT" -ge 45 ]; then
    MSG="⚠️ B2 桶用量 ${PCT}%（约 ${GB}.${MB} GB / 10GB，预警线 45%）。当前含 nearby 历史日目录过渡副本，百度基线核验后可 purge 回落。"
  else
    MSG="✅ B2 桶用量 ${PCT}%（约 ${GB}.${MB} GB / 10GB），正常。"
  fi
fi

# 变化检测：与上次通报状态相同则静默
if [ -f "$STATE" ] && [ "$(cat "$STATE")" = "$CUR" ]; then
  echo "$(date +%F" "%T) 状态未变($CUR) 静默" >> "$LOG"
  exit 0
fi
echo "$CUR" > "$STATE"
"$ALERT" "$MSG" >/dev/null 2>&1
echo "$(date +%F" "%T) 通报: $CUR" >> "$LOG"
