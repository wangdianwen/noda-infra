#!/bin/sh
# 百度上传僵死看门狗 v2（2026-10-06）
# 判活依据升级：完成数 或 日志进度条累计字节 任一变化都算活着。
# 背景：档案树尾部有 27GB 级单文件，正常传输也要数小时，v1 只看完成数会把
# 健康的大文件传输误判僵死并反复杀重启（进度清零死循环）。
# 真僵死（连接吊死、字节冻结）仍会被抓：字节不变+完成数不变超过阈值才动手。
# cron: */10 * * * *
LOG=/var/log/noda-immich-cloud.log
HB=/tmp/.cloud-upload-heartbeat
SCRIPT=/mnt/mmc1-4/System/Scripts/immich-cloud-upload.sh
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh
WLOG=/var/log/noda-upload-watchdog.log
STALL_LIMIT=5400   # 90 分钟完成数与字节均无变化即判定僵死

ps w | grep -q "[i]mmich-cloud-upload" || exit 0   # 没在跑，无事可做

NOW=$(date +%s)
CUR=$(grep -c "上传文件成功\|秒传成功" "$LOG" 2>/dev/null || echo 0)
# 最近一条进度条的已传字节（换算成 KB；上传脚本把 ↑ 进度条改写到侧文件，主日志不再膨胀）
BAR=$(tail -c 4000 /tmp/.baidu-progress 2>/dev/null | tr '\r' '\n' | grep "↑" | tail -1)
CURB=$(echo "$BAR" | sed -n 's/.*↑ \([0-9.]*\)\([KMG]\)B\/.*/\1\2/p')
[ -n "$CURB" ] || CURB="0K"
CURB=$(awk -v b="$CURB" 'BEGIN{v=b+0;u=substr(b,length(b),1);r=v; if(u=="G")r=v*1048576; else if(u=="M")r=v*1024; printf "%d", r}')

LAST_N=$(cut -d"|" -f1 "$HB" 2>/dev/null || echo -1)
LAST_B=$(cut -d"|" -f2 "$HB" 2>/dev/null || echo 0)
LAST_T=$(cut -d"|" -f3 "$HB" 2>/dev/null || echo "$NOW")

if [ "$CUR" != "$LAST_N" ] || [ "$CURB" != "$LAST_B" ]; then
  echo "$CUR|$CURB|$NOW" > "$HB"   # 有进展（新文件 或 传输中字节增长），刷新心跳
  exit 0
fi

STALL=$(( NOW - LAST_T ))
[ "$LAST_N" = "-1" ] && { echo "$CUR|$CURB|$NOW" > "$HB"; exit 0; }   # 首次见到运行中的实例，先建心跳
[ "$STALL" -lt "$STALL_LIMIT" ] && exit 0

echo "$(date +%F" "%T) 僵死判定：${STALL}s 完成数停在 $CUR、字节停在 $CURB KB，重启上传实例" >> "$WLOG"
for P in $(ps w | grep "[i]mmich-cloud-upload" | awk '{print $1}'); do kill -9 $P 2>/dev/null; done
for P in $(ps w | grep "[B]aiduPCS-Go upload" | awk '{print $1}'); do kill -9 $P 2>/dev/null; done
sleep 2
rmdir /tmp/immich-cloud-upload.lock 2>/dev/null
( setsid sh "$SCRIPT" </dev/null >/dev/null 2>&1 & )
"$ALERT" "⚠️ 百度上传停滞 $((STALL/60)) 分钟无进展（字节冻结），看门狗已自动重启实例（断点续传，已传文件不受影响）"
echo "$CUR|$(date +%s)" > "$HB"
