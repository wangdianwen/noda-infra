#!/bin/sh
# 日志瘦身（2026-10-07）：noda 日志超 2MB 保留末尾 200KB；进度条侧文件超 1MB 清空。
# /var/log 是内存盘，且上传进度条曾把单日志刷到 39MB 挤占 RAM、拖慢看门狗 grep。
# cron: 50 4 * * *
for f in /var/log/noda-*.log; do
  [ -f "$f" ] || continue
  [ "$(wc -c < "$f")" -gt 2097152 ] || continue
  tail -c 204800 "$f" > "$f.tail" && cat "$f.tail" > "$f" && rm -f "$f.tail"
done
[ -f /tmp/.baidu-progress ] && [ "$(wc -c < /tmp/.baidu-progress)" -gt 1048576 ] && : > /tmp/.baidu-progress
exit 0
