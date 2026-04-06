#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 容器启动脚本
# ============================================

set -e

echo "=========================================="
echo "Noda 备份服务容器启动"
echo "=========================================="

# 加载环境变量
if [ -f /app/.env.backup ]; then
  set -a
  source /app/.env.backup
  set +a
  echo "✓ 已加载配置文件"
fi

# 验证必需的环境变量
if [ -z "$POSTGRES_HOST" ] || [ -z "$B2_ACCOUNT_ID" ]; then
  echo "❌ 错误: 缺少必需的环境变量"
  echo "必需变量: POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, B2_ACCOUNT_ID, B2_APPLICATION_KEY, B2_BUCKET_NAME"
  exit 1
fi

echo "✓ 环境变量验证通过"

# 配置 rclone
if [ -n "$B2_ACCOUNT_ID" ] && [ -n "$B2_APPLICATION_KEY" ]; then
  mkdir -p /config/rclone
  cat > /config/rclone/rclone.conf <<EOF
[b2]
type = b2
account = $B2_ACCOUNT_ID
key = $B2_APPLICATION_KEY
EOF
  echo "✓ rclone 配置完成"
fi

# 显示定时任务
echo ""
echo "已配置的定时任务:"
crontab -l
echo ""

# 启动 cron 服务（前台运行）
echo "启动 cron 服务..."
echo "=========================================="

# 使用 crond 的前台模式
crond -f -l 2
