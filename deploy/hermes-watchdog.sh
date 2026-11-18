#!/bin/sh
# hermes gateway watchdog（r4s）— 2026-11-19 上线
# 背景：Telegram 服务端故障等网络异常会令 gateway 触发自杀重启，而 adapter 的
# self-restart 生成 `hermes gateway restart` 进程在 procd 监管之外，挂死后
# TG 入站永久停摆（2026-11-03、2026-11-19 两次事故同模式）。
# 每 5 分钟（cron */5）探测两类故障，连续 3 轮命中（≈15 分钟）即执行修复：
#   ① `hermes gateway run` 主进程缺失（含 self-restart 挂死场景）
#   ② gateway_state.json platforms.telegram.state != connected（进程在跑但 TG 卡死）
# 修复动作：杀挂死 restart 进程 → 清陈旧 gateway.pid/gateway.lock →
#   /etc/init.d/hermes restart（procd 正主）→ telegram-alert.sh TG 通报。
# 30 分钟冷却防重启风暴；计划内维护（pip 升级等）期间 touch
# /tmp/hermes-watchdog.pause 挂起探测，完事删掉。
# 退出码恒 0（检查执行了即 ok，遵循 hb 心跳约定）；动作详情见
# /var/log/noda-hermes-watchdog.log。

HERMES=/mnt/mmc1-4/Hermes/Hermes
STATE_F="$HERMES/gateway_state.json"
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh
STRIKES_F=/tmp/hermes-watchdog.strikes
COOLDOWN_F=/tmp/hermes-watchdog.cooldown
PAUSE_F=/tmp/hermes-watchdog.pause
MAX_STRIKES=3
COOLDOWN_SECS=1800

log(){ echo "[$(date '+%Y-%m-%d %T')] $*"; }

tg_state(){
  python3 -c "import json;print(json.load(open('$STATE_F')).get('platforms',{}).get('telegram',{}).get('state','unknown'))" 2>/dev/null
}

# 0) 维护挂起 / 冷却期内静默退出
if [ -f "$PAUSE_F" ]; then log "PAUSED: $PAUSE_F 存在，跳过"; exit 0; fi
now=$(date +%s)
last=$(cat "$COOLDOWN_F" 2>/dev/null)
case "$last" in ''|*[!0-9]*) last=0;; esac
if [ $(( now - last )) -lt $COOLDOWN_SECS ]; then exit 0; fi

gw=$(ps w | grep -F 'hermes gateway run' | grep -v grep | wc -l)
hung=$(ps w | grep -F 'hermes gateway restart' | grep -v grep | wc -l)
state=$(tg_state); case "$state" in ''|unreadable) state=unknown;; esac

bad=0; reason=""
if [ "$gw" -eq 0 ]; then
  bad=1; reason="gateway run 进程缺失(hung restart=$hung tg=$state)"
elif [ "$state" != "connected" ]; then
  bad=1; reason="telegram state=$state(gateway run 在跑 hung restart=$hung)"
fi

if [ "$bad" -eq 0 ]; then
  if [ -f "$STRIKES_F" ]; then log "RECOVERED: tg=$state gw=$gw，strikes 清零"; rm -f "$STRIKES_F"; fi
  exit 0
fi

strikes=$(cat "$STRIKES_F" 2>/dev/null)
case "$strikes" in ''|*[!0-9]*) strikes=0;; esac
strikes=$(( strikes + 1 ))
echo "$strikes" > "$STRIKES_F"
log "DEGRADED $strikes/$MAX_STRIKES: $reason"
if [ "$strikes" -lt "$MAX_STRIKES" ]; then exit 0; fi

log "ACTION: 杀挂死 restart($hung) → 清 gateway.pid/lock → procd restart"
for pid in $(ps w | grep -F 'hermes gateway restart' | grep -v grep | awk '{print $1}'); do
  kill "$pid" 2>/dev/null
done
sleep 3
for pid in $(ps w | grep -F 'hermes gateway restart' | grep -v grep | awk '{print $1}'); do
  kill -9 "$pid" 2>/dev/null
done
rm -f "$HERMES/gateway.pid" "$HERMES/gateway.lock"
/etc/init.d/hermes restart
sleep 45
gw2=$(ps w | grep -F 'hermes gateway run' | grep -v grep | wc -l)
state2=$(tg_state); case "$state2" in ''|unreadable) state2=unknown;; esac
log "ACTION done: gw=$gw2 tg=$state2"
if [ -x "$ALERT" ]; then
  "$ALERT" "🛠 hermes watchdog 已自动修复: $reason；重启后 gw=$gw2 tg=$state2 (r4s)"
fi
date +%s > "$COOLDOWN_F"
rm -f "$STRIKES_F"
exit 0
