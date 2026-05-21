#!/bin/bash
# Skykiwi Hobby 板块爬虫 Cronjob
# 每周一 7:00 执行，随机延迟 10分钟-12小时（防止被封）

set -e

echo "===== Skykiwi Hobby 爬虫开始 $(date) ====="

# 随机延迟 10分钟到 12小时（600秒到 43200秒）
RANDOM_DELAY=$((RANDOM % 42601 + 600))
RANDOM_MINUTES=$((RANDOM_DELAY / 60))
echo "随机延迟: ${RANDOM_MINUTES} 分钟 (${RANDOM_DELAY} 秒)"
sleep $RANDOM_DELAY
echo "===== 延迟结束，开始爬取 $(date) ====="

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
/app/crawler-venv/bin/python3 crawl-skykiwi.py --board hobby >> /var/log/noda-backup/crawler-hobby.log 2>&1

echo "===== Skykiwi Hobby 爬虫完成 $(date) ====="
