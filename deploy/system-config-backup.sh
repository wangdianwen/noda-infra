#!/bin/sh
# r4s 关键配置上云备份 v4：整树镜像到 /系统配置备份/config，云端永远单份当前态
# 策略依据（BaiduPCS-Go v4.0.2 实测约束）：
#  - 目录模式上传全灭（任何 policy 都因内部列表接口 -9 失败），只有单文件模式可靠
#  - 单文件 skip=同名/同 md5 秒传跳过；单文件 overwrite=同名覆盖、不产生第二副本
#  - 差异在本地判（状态文件记录 路径|大小|mtime），只传有变化的文件
# 用法: sh /mnt/mmc1-4/System/Scripts/system-config-backup.sh
BIN=/mnt/mmc1-4/Apps/Immich/cloud-upload/bin/BaiduPCS-Go
STAMP=$(date +%Y%m%d-%H%M)
TMP=/tmp/sys-config-backup
REMOTE="/系统配置备份/config"
STATE=/mnt/mmc1-4/System/Scripts/.sys-config-sync.state
LOCK=/tmp/.sys-config-backup.lock
LOG=/var/log/noda-sysconfig-backup.log

if [ -d "$LOCK" ]; then echo "已在运行，跳过 $STAMP"; exit 0; fi
mkdir "$LOCK" || exit 1

{
echo "=== 系统配置同步 $STAMP ==="
rm -rf "$TMP"; mkdir -p "$TMP/hermes" "$TMP/router" "$TMP/noda"

# 1) hermes：散文件原样拷。
#    注意不含 state.db（461MB 运行数据、在数据盘上由每夜快照覆盖，不属配置，勿上云）
cp -aL /root/.hermes/.env /root/.hermes/.git-pat /root/.hermes/config.yaml \
      /root/.hermes/SOUL.md /root/.hermes/auth.json \
      /root/.hermes/channel_directory.json "$TMP/hermes/" 2>/dev/null
# hermes 自有 git 仓库 + cron + gateway：单文件 tgz；gzip -n 保证未变时字节一致
tar cf - -C /root .hermes/.git .hermes/cron .hermes/gateway 2>/dev/null \
  | gzip -n > "$TMP/hermes/hermes-home-extra.tgz"
touch -r /root/.hermes/cron "$TMP/hermes/hermes-home-extra.tgz" 2>/dev/null

# 2) 路由配置（cp -a 保留 mtime）
cp -a /etc/config "$TMP/router/etc-config" 2>/dev/null
cp -a /etc/dnsmasq.conf /etc/hosts /etc/rc.local "$TMP/router/" 2>/dev/null
cp -a /mnt/mmc1-4/System/Scripts "$TMP/router/System-Scripts" 2>/dev/null
crontab -l > "$TMP/router/crontab.txt"
touch -r /etc/crontabs/root "$TMP/router/crontab.txt" 2>/dev/null

# 3) noda 配置
cp -a /opt/noda/noda-infra/docker/volumes/backup/config.sh "$TMP/noda/" 2>/dev/null

# 4) 本轮状态（路径|大小|mtime；状态文件放 TMP 外，避免被当文件上传；滤掉 0 字节空文件——百度拒收）
CUR="/tmp/.sysconfig-cur.$$"
find "$TMP" -type f -size +0 | while IFS= read -r f; do stat -c "%n|%s|%Y" "$f"; done \
  | sed "s|^$TMP/||" | sort > "$CUR"

# 5) 求差异（本地整行差集，等价 comm -23；BusyBox 无 comm 故用 awk）：状态为空=首轮全量
DIFF="/tmp/.sysconfig-diff.$$"
if [ -s "$STATE" ]; then
  awk 'NR==FNR{s[$0]=1;next} !($0 in s)' "$STATE" "$CUR" > "$DIFF"
else
  cp "$CUR" "$DIFF"
fi
N=$(wc -l < "$DIFF")
echo "待同步文件数: $N"

# 6) 远端目录镜像（只补本地存在的目录）+ 等元数据传播
"$BIN" mkdir "$REMOTE" >/dev/null 2>&1
find "$TMP" -type d | while IFS= read -r d; do
  rel="${d#"$TMP"}"; [ -n "$rel" ] && "$BIN" mkdir "$REMOTE$rel" >/dev/null 2>&1
done
sleep 5

# 7) 逐文件单文件上传：overwrite=同名覆盖刷新（配置要的是"最新单份"）
FAIL=0
while IFS= read -r line; do
  rel="${line%%|*}"; f="$TMP/$rel"
  rdir="$REMOTE$(dirname "/$rel")"
  "$BIN" mkdir "$rdir" >/dev/null 2>&1
  if "$BIN" upload "$f" "$rdir" --policy overwrite >> "$LOG" 2>&1; then
    echo "  ↻ 已同步: $rel"
  else
    echo "  ❌ 失败: $rel"; FAIL=1
  fi
done < "$DIFF"

# 状态只在全量成功后落盘；失败保留旧状态，下轮自动重传未竟文件
if [ "$FAIL" = 0 ]; then
  cp "$CUR" "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  echo "✅ 配置同步完成（$N 个文件）"
else
  echo "❌ 有文件失败（状态未更新，下轮重试）"; exit 1
fi
rm -rf "$TMP" "$CUR" "$DIFF"
echo "=== end ==="
} >> "$LOG" 2>&1

rmdir "$LOCK"
tail -12 "$LOG"
