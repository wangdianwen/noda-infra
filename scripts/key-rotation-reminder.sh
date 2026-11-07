#!/bin/bash
# key-rotation-reminder.sh — 每周 LLM 双 key 轮换 TG 提醒（launchd 每周一 09:00 调度）
# key 唯一来源：~/.config/llm-keys.env（0600）；轮换 runbook：~/.agents/skills/key-rotation/
# TG 通道：r4s telegram-alert.sh（Zcode For Ben bot → 用户 DM）
# 消息中绝不出现 key 明文，最多出现前 8 位指纹。
set -euo pipefail

KEYFILE="$HOME/.config/llm-keys.env"
[ -r "$KEYFILE" ] || { echo "✗ key 文件不可读: $KEYFILE"; exit 1; }

ROTATED_AT=$(grep '^ROTATED_AT=' "$KEYFILE" | cut -d= -f2)
[ -n "$ROTATED_AT" ] || ROTATED_AT="未记录"

K1_FP=$(grep '^ZCODE_SCRIPT_KEY=' "$KEYFILE" | cut -d= -f2 | cut -c1-8)
K2_FP=$(grep '^LLM_SCRIPTS_KEY=' "$KEYFILE" | cut -d= -f2 | cut -c1-8)

MSG="🔑 每周 key 轮换提醒：LLM 双 key 上次轮换 ${ROTATED_AT}（coding ${K1_FP}…=Hermes/代码链路，llm ${K2_FP}…=noda 线上）。请到 z.ai 控制台生成 2 个新 key，写入 ~/.config/llm-keys.env（ZCODE_SCRIPT_KEY / LLM_SCRIPTS_KEY / ROTATED_AT），然后对我说『执行 key 轮换』即可，我会按 /key-rotation runbook 完成全部替换点。"

# 经 r4s 发送（r4s 持 TG bot token）
OUT=$(ssh -o ConnectTimeout=15 r4s "/mnt/mmc1-4/System/Scripts/telegram-alert.sh \"${MSG}\"; echo SSH_RC=\$?" 2>&1) || {
  echo "✗ ssh r4s 失败：${OUT}"
  exit 1
}
SSH_RC=$(echo "$OUT" | grep -o 'SSH_RC=[0-9]*' | cut -d= -f2)
[ "$SSH_RC" = "0" ] || { echo "✗ TG 发送失败（r4s 退出码 ${SSH_RC:-未知}）"; exit 1; }
echo "$(date '+%F %T') ✓ 提醒已发送（ROTATED_AT=${ROTATED_AT}）"
