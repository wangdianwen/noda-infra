#!/bin/bash
# Skykiwi 每日爬虫任务
# 每天 7:00 执行，随机延迟 10 分钟 - 12 小时
# 在 noda-ops 容器内运行
# 功能：爬取 → 保存JSON → 自动导入数据库

set -e

# 随机延迟：10 分钟 (600秒) 到 12 小时 (43200秒)
MIN_DELAY=600
MAX_DELAY=43200
RANDOM_DELAY=$((RANDOM % (MAX_DELAY - MIN_DELAY + 1) + MIN_DELAY))

HOURS=$((RANDOM_DELAY / 3600))
MINUTES=$(((RANDOM_DELAY % 3600) / 60))
SECONDS=$((RANDOM_DELAY % 60))

OUTPUT_DIR="/var/log/noda-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/hobby-courses-${TIMESTAMP}.json"

echo "⏰ [$(date)] Skykiwi 爬虫任务开始"
echo "⏰ [$(date)] 随机延迟: ${HOURS}小时 ${MINUTES}分钟 ${SECONDS}秒 (总计 ${RANDOM_DELAY}秒)"

sleep $RANDOM_DELAY

echo "✅ [$(date)] 延迟结束，开始执行爬虫"

# 切换到爬虫目录并执行，保存输出到文件
cd /app/crawler
echo "📝 [$(date)] 爬取 Hobby 板块..."
/app/crawler-venv/bin/python3 crawl-skykiwi.py --board hobby > "$OUTPUT_FILE" 2>&1

echo "✅ [$(date)] 爬取完成，输出文件: $OUTPUT_FILE"

# 自动导入数据库
echo "📥 [$(date)] 开始导入数据库..."
/app/crawler-venv/bin/python3 import-courses.py "$OUTPUT_FILE"

echo "✅ [$(date)] 爬虫任务完成（已导入数据库）"
