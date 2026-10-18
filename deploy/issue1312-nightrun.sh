#!/bin/sh
# issue1312 夜跑（2026-10-17 一次性，跑完移除 cron）：宿主侧逐轮 docker exec，
# 容器重建免疫（并行会话部署会杀容器内 wrapper 的坑，20:45 实证两次）。
LOG=/var/log/issue1312-nightrun.log
run_round() {
  name="$1"; limit_env="$2"; cmd="$3"
  echo "=== $name round $(date) ===" >> "$LOG"
  docker exec noda-jobs-prod sh -c "$limit_env crawl-nearby $cmd" >> "$LOG" 2>&1
}
# newsfull 6 轮（剩 ~3400 行）+ placedesc 4 轮（全量 3853 行）
i=1
while [ $i -le 6 ]; do
  run_round newsfull "NEARBY_NEWS_FULLTEXT_LIMIT=900" newsfull
  [ $i -lt 6 ] && sleep 600
  i=$((i+1))
done
j=1
while [ $j -le 4 ]; do
  run_round placedesc "NEARBY_PLACE_DESC_LIMIT=1200" placedescriptions
  [ $j -lt 4 ] && sleep 1800
  j=$((j+1))
done
echo "=== ALL DONE $(date) ===" >> "$LOG"
