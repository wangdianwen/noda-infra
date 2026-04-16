#!/bin/bash
# Skykiwi 爬虫入口脚本
#
# 模式:
#   run  — 单次执行爬虫后退出
#   cron — 启动 cron 守护进程，按计划定时执行
set -e

MODE="${1:-cron}"

case "$MODE" in
  run)
    echo "[$(date)] 开始执行 Skykiwi 爬虫（单次模式）..."
    python3 -B scripts/crawl-skykiwi.py --all-boards
    echo "[$(date)] 爬虫执行完毕"
    ;;
  cron)
    echo "[$(date)] 启动 Skykiwi 爬虫定时调度..."
    echo "[$(date)] 定时计划: 每天 UTC 18:00 / NZST 06:00"
    echo "[$(date)] 查看日志: docker compose logs -f skykiwi-crawler"
    echo "[$(date)] 手动触发: docker compose exec skykiwi-crawler /app/entrypoint.sh run"
    # 启动 cron 守护进程（前台运行）
    cron -f
    ;;
  *)
    echo "用法: $0 [run|cron]"
    echo "  run  — 单次执行"
    echo "  cron — 定时调度（默认）"
    exit 1
    ;;
esac
