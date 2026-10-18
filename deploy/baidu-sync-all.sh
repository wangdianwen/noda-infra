#!/bin/sh
# 统一百度云同步入口（2026-10-03，2026-10-18 增第三段）：r4s 全部上云数据一个任务收口
#   第一段：系统配置整树增量（小而快，秒级~分钟级，先传保证及时性）
#   第二段：照片两棵树增量 + DB 转储（大而慢；161G 基线期间内部锁自动跳过当日重入）
#   第三段：nearby 爬取素材增量（weed S3→staging→/noda备份/nearby；2026-10-18 自 B2 免费额度挪出）
# 各段独立锁、独立 Telegram 告警；本入口只负责串行编排与汇总日志
# 由 crontab 每天 03:30 调用；日志 /var/log/noda-baidu-sync-all.log
SCRIPTS=/mnt/mmc1-4/System/Scripts
ALERT=$SCRIPTS/telegram-alert.sh
LOG=/var/log/noda-baidu-sync-all.log
LOCK=/tmp/.baidu-sync-all.lock
[ -d "$LOCK" ] && { echo "$(date +%F" "%T) 上锁跳过（统一任务已在跑）" >> "$LOG"; exit 0; }
mkdir "$LOCK" || exit 1
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

echo "=== 统一百度同步开始 $(date +%F" "%T) ===" >> "$LOG"
RC=0
# 1) 系统配置（hermes/OpenWrt/Scripts/crontab/noda → /系统配置备份/config）
sh "$SCRIPTS/system-config-backup.sh" >> "$LOG" 2>&1 \
  || { "$ALERT" "❌ 统一百度同步：配置部分失败，详见 r4s:/var/log/noda-sysconfig-backup.log"; RC=1; }
# 2) 照片 + DB（手机原图树 + 老照片档案树 + immich-db-latest → /Immich备份/）
( setsid sh "$SCRIPTS/immich-cloud-upload.sh" >> "$LOG" 2>&1 & )
# 3) nearby 爬取素材（weed S3 staging 后单文件上传 → /noda备份/nearby）
( setsid sh "$SCRIPTS/nearby-baidu-backup.sh" >> "$LOG" 2>&1 & )
echo "=== 统一百度同步结束 rc=$RC $(date +%F" "%T) ===" >> "$LOG"
exit $RC
