#!/bin/sh
# geo-enforce-flip.sh：#19 geo-challenge observe→enforce 定时翻转（crontab 年
# 度 11-24 17:30 首跑；observe 自 2026-11-17 起算满 7 天）。
# 守卫（不满足任一即不翻）：
#   1. marker /etc/noda/geo-enforce-flipped 已存在 → 已翻过，幂等退出；
#   2. /var/log/noda-ip-ban.log 存在 geo-rule 漂移/缺失记录 → 只 TG 告警等
#      人工核查（observe 期出现过漂移说明 canonical 与期望不符，自动翻有
#      误写风险——#19 风险边界条款）；
#   3. 环境文件已是 enforce → 补 marker 幂等退出。
# 翻转动作：/etc/noda/ip-ban.env 追加 GEO_RULE_MODE=enforce（geo_rule_mode()
# 下一轮 */5 生效），touch marker，TG 两端通知（成功/守卫拦截）。
# 回滚：删掉 env 行即可回 observe（marker 保留防年度重放，回滚后想再自动翻
# 须连 marker 一起删）。
MARKER=/etc/noda/geo-enforce-flipped
ENV_FILE=/etc/noda/ip-ban.env
LOG=/var/log/noda-ip-ban.log
TG=/mnt/mmc1-4/System/Scripts/telegram-alert.sh

if [ -f "$MARKER" ]; then
  exit 0
fi
if grep -q '^GEO_RULE_MODE=enforce' "$ENV_FILE" 2>/dev/null; then
  touch "$MARKER"
  exit 0
fi
if grep -q 'geo-rule\[.*\]: drift detected\|geo-rule\[.*\]: missing' "$LOG" 2>/dev/null; then
  "$TG" "geo-enforce-flip: ip-ban 日志存在 geo-rule 漂移/缺失记录，未自动翻转 enforce——请人工核查 canonical 后手动设置 GEO_RULE_MODE（#19 风险边界）" 2>/dev/null
  exit 1
fi
echo 'GEO_RULE_MODE=enforce' >> "$ENV_FILE"
touch "$MARKER"
"$TG" "geo-enforce-flip: geo-challenge observe 满一周零漂移，已写入 GEO_RULE_MODE=enforce（$ENV_FILE），下一轮 ip-ban（*/5）起 enforce 自愈生效（#19 Phase 2）" 2>/dev/null
exit 0
