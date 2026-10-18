#!/bin/sh
# r4s 数据盘 → /mnt/backup 硬链接增量快照（保留 2 代，空间紧张自动降代）
# 排除可再生内容（docker/缓存/日志）与活数据库（Immich 库走 backupDatabase 的 pg_dump）
# cron: 10 5 * * *（见 root crontab）；手动重跑幂等（当日目录续传）
# 2026-10-02 目录按功能重组后排除清单同步更新（Hermes/Noda/Apps/Archive/System/99-Legacy 布局）
SRC=/mnt/mmc1-4
DST=/mnt/backup/snapshot
KEEP=2
LOG_TAG="$(date "+%F %T")"
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh

# 互斥：一次只跑一个
if ! mkdir /tmp/noda-snapshot.lock 2>/dev/null; then
  echo "$LOG_TAG 已有实例在跑，跳过"
  exit 0
fi
trap "rmdir /tmp/noda-snapshot.lock 2>/dev/null" EXIT

# 发版避让：Jenkins 发版期间（r4s 侧部署锁存在）自动推迟，最多等 30 分钟
DEPLOY_WAITED=0
while ls /tmp/noda-deploy-*.lock >/dev/null 2>&1; do
  if [ "$DEPLOY_WAITED" -ge 30 ]; then
    echo "$LOG_TAG 发版锁超过 30 分钟未释放，本轮快照跳过（下轮 cron 再试）"
    exit 0
  fi
  [ "$DEPLOY_WAITED" -eq 0 ] && echo "$LOG_TAG 检测到发版进行中，快照避让等待..."
  sleep 300
  DEPLOY_WAITED=$((DEPLOY_WAITED+5))
done

[ -d "$DST" ] || mkdir -p "$DST"

TODAY=$(date +%F)
TODAY_DIR="$DST/snap.$TODAY"

gen_list() { ls -1d "$DST"/snap.* 2>/dev/null | grep -v "^$TODAY_DIR\$" | sort; }

# 空间压力自愈：余量 <25G 且已有 ≥2 代 → 淘汰最老一代再跑（降级为单副本保护）
FREE_KB=$(df -k /mnt/backup | tail -1 | awk "{print \$4}")
if [ "$FREE_KB" -lt $((25*1024*1024)) ]; then
  OLDEST=$(gen_list | head -1)
  GENS=$(gen_list | wc -l)
  if [ -n "$OLDEST" ] && [ "$GENS" -ge 2 ]; then
    echo "$LOG_TAG 空间紧张（余量 $((FREE_KB/1024/1024))G < 25G），自动淘汰最老一代 $OLDEST（降为 1 代保护）"
    rm -rf "$OLDEST"
    "$ALERT" "⚠️ r4s 备份分区空间紧张（余量 $((FREE_KB/1024/1024))G），已自动淘汰最老一代快照，降为单代保护"
  fi
fi

PREV=$(gen_list | tail -1)

# 空间门：无旧代可硬链接（首轮）时必须有足够全量空间
FREE_KB=$(df -k /mnt/backup | tail -1 | awk "{print \$4}")
if [ "$FREE_KB" -lt $((15*1024*1024)) ] && [ -z "$PREV" ]; then
  echo "$LOG_TAG 备份盘余量不足 15G 且无旧代可硬链接，放弃（勿删数据盘！）"
  exit 1
fi

mkdir -p "$TODAY_DIR"
LINKOPT=""
[ -n "$PREV" ] && LINKOPT="--link-dest=$PREV"

echo "$LOG_TAG 快照开始 → $TODAY_DIR（link-dest: ${PREV:-无，首轮全量}）"
nice -n 19 rsync -aHx --delete --numeric-ids --info=stats1,progress0 \
  $LINKOPT \
  --exclude="/System/Docker" \
  --exclude="/System/uv-cache" \
  --exclude="/System/Scripts/shuotong_dns.log" \
  --exclude="/System/Scripts/syslog.log" \
  --exclude="/System/Scripts/syslog.log.old" \
  --exclude="/lost+found" \
  --exclude="/Apps/Immich" \
  --exclude="/99-Legacy" \
  --exclude="/家庭文件/tt/照片" \
  --exclude="/System/swapfile" \
  "$SRC/" "$TODAY_DIR/"
RC=$?

if [ $RC -ne 0 ]; then
  echo "$LOG_TAG rsync 失败 rc=$RC（保留现场供排查；数据盘不受影响）"
  "$ALERT" "❌ r4s 每夜快照失败 rc=$RC（数据盘不受影响；快照目录保留现场），详见 /var/log/noda-snapshot.log"
  exit $RC
fi

# 闪存配置第三副本（2026-10-03）：快照只覆盖数据盘，/etc 与 hermes 主目录单独打包随代保存，
# 与百度云配置同步互为独立副本（~15MB/代）
FLASH_TGZ="$TODAY_DIR/flash-configs.tar.gz"
if tar czf "$FLASH_TGZ" -C / etc/config etc/dnsmasq.conf etc/hosts etc/rc.local \
     root/.hermes/.env root/.hermes/.git-pat root/.hermes/config.yaml root/.hermes/SOUL.md \
     root/.hermes/auth.json root/.hermes/channel_directory.json \
     root/.hermes/.git root/.hermes/cron root/.hermes/gateway 2>/dev/null \
   && gzip -t "$FLASH_TGZ"; then
  echo "$LOG_TAG 闪存配置包 OK（$(du -k "$FLASH_TGZ" | cut -f1)KB）"
else
  echo "$LOG_TAG ⚠️ 闪存配置包失败（不影响数据盘快照本体）"
  "$ALERT" "⚠️ r4s 每夜快照：闪存配置包打包失败（数据盘快照本体正常），详见 /var/log/noda-snapshot.log"
fi

# 轮换：只保留最新 KEEP 代
ls -1d "$DST"/snap.* 2>/dev/null | grep -v "^$TODAY_DIR\$" | sort | head -n -"$KEEP" | while read -r OLD; do
  echo "$LOG_TAG 淘汰旧代 $OLD"
  rm -rf "$OLD"
done

SIZE=$(du -sh "$TODAY_DIR" 2>/dev/null | cut -f1)
FREE=$(df -h /mnt/backup | tail -1 | awk "{print \$4}")
GENS=$(ls -1d "$DST"/snap.* 2>/dev/null | wc -l)
echo "$LOG_TAG 快照完成 本代=$SIZE 代数=$GENS 备份盘余量=$FREE"
