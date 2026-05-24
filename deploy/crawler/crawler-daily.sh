#!/bin/bash
# Skykiwi 每日爬虫任务
# 每天 7:00 执行，随机延迟 10 分钟 - 12 小时
# 在 noda-ops 容器内运行

set -e

# 随机延迟：10 分钟 (600秒) 到 12 小时 (43200秒)
MIN_DELAY=600
MAX_DELAY=43200
RANDOM_DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))

HOURS=$((RANDOM_DELAY / 3600))
MINUTES=$(((RANDOM_DELAY % 3600) / 60))
SECONDS=$((RANDOM_DELAY % 60))

echo "⏰ [$(date)] Skykiwi 爬虫任务开始"
echo "⏰ [$(date)] 随机延迟: ${HOURS}小时 ${MINUTES}分钟 ${SECONDS}秒 (总计 ${RANDOM_DELAY}秒)"

sleep $RANDOM_DELAY

echo "✅ [$(date)] 延迟结束，开始执行爬虫"

# 切换到爬虫目录并执行
cd /app/crawler
/app/crawler-venv/bin/python3 crawl-skykiwi.py --board hobby

echo "✅ [$(date)] 爬虫任务完成"
