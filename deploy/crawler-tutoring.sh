#!/bin/bash
# Skykiwi Tutoring 板块爬虫 Cronjob
# 每天 7:00 执行，抓取第一页所有内容

set -e

# --now: 跳过随机延迟，立即执行（用于手动触发）
SKIP_DELAY=false
for arg in "$@"; do
    [[ "$arg" == "--now" ]] && SKIP_DELAY=true
done

echo "===== Skykiwi Tutoring 爬虫开始 $(date) ====="

if [[ "$SKIP_DELAY" == "false" ]]; then
    RANDOM_DELAY=$((RANDOM % 42601 + 600))
    RANDOM_MINUTES=$((RANDOM_DELAY / 60))
    echo "随机延迟: ${RANDOM_MINUTES} 分钟 (${RANDOM_DELAY} 秒)"
    sleep $RANDOM_DELAY
    echo "===== 延迟结束，开始爬取 $(date) ====="
else
    echo "手动触发，跳过延迟"
fi

# 设置环境变量
export DATABASE_URL="postgresql://postgres:postgres_password_change_me@noda-infra-postgres-prod:5432/noda_prod"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.z.ai/api/anthropic}"
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN}"

# 检查 API key
if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "错误：ANTHROPIC_API_KEY 未设置，跳过爬虫"
    exit 1
fi

# 运行爬虫（使用虚拟环境中的 Python）
cd /app/crawler
/app/crawler-venv/bin/python3 crawl-skykiwi.py --board tutoring \
    1> /app/crawler/logs/crawl_output_tutoring_$(date +%Y%m%d).json \
    2>> /var/log/noda-backup/crawler-tutoring.log

echo "===== Skykiwi Tutoring 爬虫完成 $(date) ====="

# 爬虫完成后立即执行课程入库
echo "===== 开始课程入库 $(date) ====="
cd /app/crawler
/usr/bin/python3 import-courses.py >> /var/log/noda-backup/import-courses.log 2>&1
echo "===== 课程入库完成 $(date) ====="
