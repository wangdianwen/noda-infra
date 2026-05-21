#!/bin/bash
# 课程入库 Cronjob
# 每天凌晨 8:00 执行（爬虫 7:00 之后）

set -e

echo "===== 课程入库开始 $(date) ====="

# 设置环境变量
export DATABASE_URL="postgresql://postgres:postgres_password_change_me@noda-infra-postgres-prod:5432/noda_prod"

# 运行入库脚本
cd /app/crawler
/usr/bin/python3 /app/crawler/import-courses.py >> /var/log/noda-backup/import-courses.log 2>&1

echo "===== 课程入库完成 $(date) ====="
