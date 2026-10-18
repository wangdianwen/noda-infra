#!/bin/sh
# nearby 爬取素材 → 百度 冷备 v1（2026-10-18，自 B2 免费额度挪出；B2 侧同日停止 nearby 新增上传）
# 源在 weed S3（宿主机无 rclone），经 noda-ops 容器 rclone（RCLONE_CONFIG_* env 式凭据，零落盘）
# 分批拉到 staging（volumes/backup 挂载=大盘），单文件上传成功即记状态+删暂存 → 暂存占用有界（批级）
# 状态文件口径：weed lsjson 的 路径|大小|ModTime；文件名=内容哈希 append-only，skip 策略幂等
# 删除不传播（宁多勿缺）；失败下轮只补失败（状态驱动）；≥1000 文件基线完成发 TG
BIN=/mnt/mmc1-4/Apps/Immich/cloud-upload/bin/BaiduPCS-Go
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh
LOG=/var/log/noda-nearby-cloud.log
STATE=/mnt/mmc1-4/System/Scripts/.cloud-sync-state-nearby
STAGE=/opt/noda/noda-infra/docker/volumes/backup/nearby-staging
STAGE_IN_CONTAINER=/tmp/postgres_backups/nearby-staging
RTREE="/noda备份/nearby"
SRC=s3weed:noda-static/nearby
BATCH=300
PAR=6
LOCK=/tmp/nearby-baidu.lock
# rclone 凭据经容器内环境变量注入（SEAWEED_S3_*），config 零落盘；
# 注意 rclone 查 env 配置时远端名转大写：必须 RCLONE_CONFIG_S3WEED_*（小写静默失效，10-18 实证）
RCMD='RCLONE_CONFIG_S3WEED_TYPE=s3 RCLONE_CONFIG_S3WEED_ACCESS_KEY_ID="$SEAWEED_S3_ACCESS_KEY" RCLONE_CONFIG_S3WEED_SECRET_ACCESS_KEY="$SEAWEED_S3_SECRET_KEY" RCLONE_CONFIG_S3WEED_ENDPOINT="${SEAWEED_S3_ENDPOINT:-http://seaweedfs:8333}" rclone'

mkdir "$LOCK" 2>/dev/null || { echo "$(date +%F" "%T) 上锁跳过（已在跑）" >> "$LOG"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
T=/tmp/.nearby-$$
echo "=== nearby→百度 开始 $(date +%F" "%T) ===" >> "$LOG"

# 登录探测（quota 用 BDUSS 即可）
if ! "$BIN" quota >/dev/null 2>&1; then
  "$ALERT" "❌ nearby→百度：百度登录失效（BDUSS/STOKEN 过期）。请重新提取 BDUSS+STOKEN 发给助手。"
  echo "$(date +%F" "%T) 登录失效，已告警" >> "$LOG"
  exit 1
fi

# weed 清单（lsjson 每行一个 JSON：Path,Name,Size,MimeType,ModTime → 路径|大小|ModTime）
docker exec noda-ops sh -c "$RCMD lsjson $SRC --recursive --files-only" 2>/dev/null \
  | sed -n 's/^{"Path":"\([^"]*\)","Name":"[^"]*","Size":\([0-9]*\),"MimeType":"[^"]*","ModTime":"\([^"]*\)".*/\1|\2|\3/p' \
  | LC_ALL=C sort > "$T.cur"
if [ ! -s "$T.cur" ]; then
  "$ALERT" "❌ nearby→百度：weed 清单查询失败（rclone lsjson 空，查 noda-ops 容器与 SEAWEED_S3 凭据）"
  echo "$(date +%F" "%T) 清单查询失败" >> "$LOG"
  rm -f "$T.cur"
  exit 1
fi

# 状态差集 = 待同步
if [ -s "$STATE" ]; then
  awk 'NR==FNR{s[$0]=1;next} !($0 in s)' "$STATE" "$T.cur" > "$T.diff"
else
  cp "$T.cur" "$T.diff"
fi
N=$(wc -l < "$T.diff")
echo "$(date +%F" "%T) 待同步: $N" >> "$LOG"
if [ "$N" = 0 ]; then
  rm -f "$T.cur" "$T.diff"
  echo "=== 无增量结束 $(date +%F" "%T) ===" >> "$LOG"
  exit 0
fi

# 预建远端目录（upload 不自动建目录；8 路并行，同 immich 管线）
awk -F'|' '{print $1}' "$T.diff" | while IFS= read -r rel; do dirname "/$rel"; done | LC_ALL=C sort -u > "$T.dirs"
n=0
while IFS= read -r d; do
  "$BIN" mkdir "$RTREE$d" >/dev/null 2>&1 &
  n=$((n+1)); [ $((n % 8)) = 0 ] && wait
done < "$T.dirs"
wait
rm -f "$T.dirs"
sleep 5

mkdir -p "$STAGE"
TOTAL_OK=0; TOTAL_NG=0
BEFORE_LINES=0; [ -f "$STATE" ] && BEFORE_LINES=$(wc -l < "$STATE")
# 分批（本机 BusyBox 无 split applet，用 sed 行号区间取批）
BI=0
while :; do
  BI=$((BI+1))
  START=$(( (BI-1)*BATCH+1 )); END=$(( BI*BATCH ))
  sed -n "${START},${END}p" "$T.diff" > "$T.b1"
  [ -s "$T.b1" ] || break
  # 批内清单写入 staging（容器可见），rclone 按清单只拉缺失文件
  awk -F'|' '{print $1}' "$T.b1" > "$STAGE/.files-from"
  awk -F'|' '{print $1}' "$T.b1" > "$T.files"
  docker exec noda-ops sh -c "$RCMD copy $SRC $STAGE_IN_CONTAINER --files-from $STAGE_IN_CONTAINER/.files-from" >/dev/null 2>&1
  CPRC=$?
  # 单文件上传（skip=同名跳过）；成功记状态+删暂存，失败留痕下轮补
  rm -f "$T.nglist"
  n=0
  while IFS= read -r rel; do
    if [ ! -f "$STAGE/$rel" ]; then echo "$rel" >> "$T.nglist"; continue; fi
    rdir="$RTREE$(dirname "/$rel")"
    ( if "$BIN" upload "$STAGE/$rel" "$rdir" --policy skip >/dev/null 2>&1; then
        grep "^$rel|" "$T.b1" | head -1 >> "$STATE"
        rm -f "$STAGE/$rel"
      else
        echo "$rel" >> "$T.nglist"
      fi ) &
    n=$((n+1)); [ $((n % PAR)) = 0 ] && wait
  done < "$T.files"
  wait
  BROWS=$(wc -l < "$T.b1")
  BNG=0; [ -f "$T.nglist" ] && BNG=$(wc -l < "$T.nglist")
  BOK=$((BROWS-BNG))
  TOTAL_OK=$((TOTAL_OK+BOK)); TOTAL_NG=$((TOTAL_NG+BNG))
  echo "$(date +%F" "%T) 批$BI: 上传成功 $BOK / 失败 $BNG / 拉取rc=$CPRC" >> "$LOG"
  rm -f "$T.files" "$STAGE/.files-from"
done

# 状态去重整理（BusyBox sort 无 -o，tmp+mv）
if [ -f "$STATE" ]; then
  LC_ALL=C sort -u "$STATE" > "$STATE.tmp" 2>/dev/null && mv "$STATE.tmp" "$STATE"
fi
# 账目自洽守卫：报成功数必须与状态文件增长一致（防「循环空转虚报成功」，2026-10-18 实证过）
FINAL_LINES=0; [ -f "$STATE" ] && FINAL_LINES=$(wc -l < "$STATE")
if [ "$TOTAL_OK" -gt 0 ] && [ "$FINAL_LINES" -le "$BEFORE_LINES" ]; then
  "$ALERT" "❌ nearby→百度：账目异常（上报成功 $TOTAL_OK 但状态文件 ${BEFORE_LINES}→${FINAL_LINES} 行未增长），本轮结果不可信，请人工核查 /var/log/noda-nearby-cloud.log"
  echo "$(date +%F" "%T) 账目异常：报成功 $TOTAL_OK 但状态 ${BEFORE_LINES}→${FINAL_LINES}" >> "$LOG"
  exit 1
fi
echo "$(date +%F" "%T) 汇总: 成功 $TOTAL_OK / 失败 $TOTAL_NG（待同步 $N）" >> "$LOG"

# 暂存清理（成功文件已删；失败文件下轮按状态重拉，这里不留本地）
find "$STAGE" -type f -delete 2>/dev/null
rm -f "$T.cur" "$T.diff" "$T.b1" 2>/dev/null

if [ "$TOTAL_NG" -gt 0 ]; then
  "$ALERT" "❌ nearby→百度：$TOTAL_NG 个文件上传失败（本轮成功 $TOTAL_OK/$N），详见 r4s:/var/log/noda-nearby-cloud.log；状态已保留，下轮只补失败"
  echo "=== 失败结束 $(date +%F" "%T) ===" >> "$LOG"
  exit 1
fi
if [ "$TOTAL_OK" -ge 1000 ]; then
  "$ALERT" "✅ nearby→百度 基线完成：本轮实际成功上传 $TOTAL_OK 个文件，转入每日增量模式"
fi
echo "=== 全部成功结束 $(date +%F" "%T) ===" >> "$LOG"
exit 0
