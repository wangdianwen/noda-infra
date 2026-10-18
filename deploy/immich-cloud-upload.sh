#!/bin/sh
# Immich -> 百度 冷备 v3（纯单文件架构）
# v3：树先传、DB 转储挪最后（限速窗口 28MB 大文件前台爬不完→看门狗杀→重启再爬的死循环）；
#     成功一个文件即写状态（重启零重扫，替代整树成功才落盘）
# 依据（BaiduPCS-Go v4.0.2 实测）：目录模式上传全灭（内部列表接口 -9），只有单文件可靠
# 差异在本地判：状态文件记录 路径|大小|mtime，sort+comm 求差，只传新增/变化文件
# 照片 UUID 文件名=身份：skip 策略下同名/同 md5 秒传跳过 → 云端永不重复、单份当前态
# 删除不传播（云端保留已备文件，宁多勿缺）；失败自动 Telegram 告警
BIN=/mnt/mmc1-4/Apps/Immich/cloud-upload/bin/BaiduPCS-Go
LOCK=/tmp/immich-cloud-upload.lock
ALERT=/mnt/mmc1-4/System/Scripts/telegram-alert.sh
LOG=/var/log/noda-immich-cloud.log
STATEDIR=/mnt/mmc1-4/System/Scripts
DUMPS=/mnt/mmc1-4/Apps/Immich/cloud-upload/db-dumps
PAR=6
mkdir "$LOCK" 2>/dev/null || { echo "$(date +%F" "%T) 上锁跳过（已在跑）" >> "$LOG"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# 登录探测（quota 用 BDUSS 即可）
if ! "$BIN" quota >/dev/null 2>&1; then
  "$ALERT" "❌ Immich→百度 云备份失败：登录失效（BDUSS/STOKEN 过期）。请重新提取 BDUSS+STOKEN 发给助手。"
  echo "$(date +%F" "%T) 登录失效，已告警" >> "$LOG"
  exit 1
fi

RC=0

# 通用：单文件增量同步一棵树。$1=本地源 $2=远端目标 $3=状态文件 $4=标签
sync_tree() {
  SRC="$1"; RTREE="$2"; ST="$3"; TAG="$4"
  CUR="/tmp/.cloudsync-cur.$$"; DIFF="/tmp/.cloudsync-diff.$$"
  FAILD="/tmp/.cloudsync-fail.$$"
  rm -rf "$FAILD"; mkdir "$FAILD"
  find "$SRC" -type f | while IFS= read -r f; do stat -c "%n|%s|%Y" "$f"; done \
    | sed "s|^$SRC/||" | sort > "$CUR"
  if [ -s "$ST" ]; then
    awk 'NR==FNR{s[$0]=1;next} !($0 in s)' "$ST" "$CUR" > "$DIFF"
  else
    cp "$CUR" "$DIFF"
  fi
  N=$(wc -l < "$DIFF")
  echo "$(date +%F" "%T) [$TAG] 待同步: $N" >> "$LOG"
  if [ "$N" = 0 ]; then rm -f "$CUR" "$DIFF"; rm -rf "$FAILD"; return 0; fi

  # 只为待传文件的父目录预建远端目录（upload 不自动建目录）
  DLIST="/tmp/.cloudsync-dirs.$$"
  cut -d'|' -f1 "$DIFF" | while IFS= read -r rel; do dirname "/$rel"; done | sort -u > "$DLIST"
  # 8 路并行预建远端目录（串行 2s/个曾是基线启动的最大瓶颈）
  n=0
  while IFS= read -r d; do
    "$BIN" mkdir "$RTREE$d" >/dev/null 2>&1 &
    n=$((n+1)); [ $((n % 8)) = 0 ] && wait
  done < "$DLIST"
  wait
  rm -f "$DLIST"
  sleep 5

  # 小批量并行单文件上传（skip=秒传/同名跳过）；成功一个即追加状态（重启零重扫），末批必须 wait
  # 进度条(↑)改写侧文件 /tmp/.baidu-progress（看门狗字节判活用），主日志只留结果行——控制日志增量
  n=0
  while IFS= read -r line; do
    rel=${line%%|*}
    idx=$(( $(cat "$FAILD/n" 2>/dev/null || echo 0) + 1 )); echo "$idx" > "$FAILD/n"
    rdir="$RTREE$(dirname "/$rel")"
    ( "$BIN" upload "$SRC/$rel" "$rdir" --policy skip > "$FAILD/out.$idx" 2>&1; RC=$?
      awk '/↑/{print >> "/tmp/.baidu-progress"; next} {print >> "'"$LOG"'"}' "$FAILD/out.$idx"
      rm -f "$FAILD/out.$idx"; exit $RC ) \
      && { echo "$line" >> "$ST"; echo ok > "$FAILD/$idx"; } \
      || echo fail > "$FAILD/$idx" &
    n=$((n+1))
    [ $((n % PAR)) = 0 ] && wait
  done < "$DIFF"
  wait
  # 去重整理（增量追加可能有重复行；awk 成员判断与顺序无关，中途乱序无害）
  # 注意 BusyBox sort 无 -o，须 tmp+mv
  LC_ALL=C sort -u "$ST" > "$ST.tmp" 2>/dev/null && mv "$ST.tmp" "$ST"
  OK=$(grep -l ok "$FAILD"/* 2>/dev/null | wc -l)
  NG=$(grep -l fail "$FAILD"/* 2>/dev/null | wc -l)
  echo "$(date +%F" "%T) [$TAG] 成功 $OK / 失败 $NG" >> "$LOG"
  rm -rf "$FAILD"
  if [ "$NG" = 0 ]; then
    # 基线级大批量完成时通知（>=1000 文件）；日常小增量不打扰
    if [ "$N" -ge 1000 ]; then
      "$ALERT" "✅ 百度云基线段完成 [$TAG]：$N 个文件全量上传成功，该树转入每日增量模式"
    fi
    RC=0
  else
    "$ALERT" "❌ Immich→百度 [$TAG]：$NG 个文件上传失败，详见 r4s:/var/log/noda-immich-cloud.log（已传部分状态已保留，下轮只补失败）"
    RC=1
  fi
  rm -f "$CUR" "$DIFF"
  return $RC
}

# 手机上传原图（UUID 名=身份，skip 防重复）
sync_tree /mnt/mmc1-4/Apps/Immich/library/library "/Immich备份/手机上传原图" "$STATEDIR/.cloud-sync-state-phone" "手机原图" || RC=1
# 老照片档案（只读源 123.7G，首次全量后每日仅增量）
sync_tree /mnt/mmc1-4/家庭文件/tt/照片 "/Immich备份/老照片档案" "$STATEDIR/.cloud-sync-state-archive" "老照片档案" || RC=1

# 每日新鲜 DB 转储——放最后（限速窗口里 28MB 前台爬不完会堵死全部照片树；树完成后才轮到它）
mkdir -p "$DUMPS"
docker exec immich_postgres pg_dump -U postgres immich | gzip > "$DUMPS/immich-db-latest.sql.gz" && gzip -t "$DUMPS/immich-db-latest.sql.gz" \
  && echo "$(date +%F" "%T) DB 转储刷新 OK" >> "$LOG"
"$BIN" mkdir "/Immich备份/db" >/dev/null 2>&1
"$BIN" upload "$DUMPS/immich-db-latest.sql.gz" "/Immich备份/db" --policy overwrite > /tmp/.up-out-db 2>&1
DBRC=$?
awk '/↑/{print >> "/tmp/.baidu-progress"; next} {print >> "'"$LOG"'"}' /tmp/.up-out-db
rm -f /tmp/.up-out-db
if [ "$DBRC" = 0 ]; then
  echo "$(date +%F" "%T) [DB] 转储上传完成" >> "$LOG"
else
  "$ALERT" "❌ Immich→百度 [DB]：转储上传失败（照片树已完成）"
  RC=1
fi

echo "$(date +%F" "%T) 增量完成 (rc=$RC)" >> "$LOG"
exit $RC
