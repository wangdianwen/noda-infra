#!/bin/bash
# ============================================
# Noda Ops - 容器启动脚本
# ============================================
# 初始化备份系统和 Cloudflare Tunnel 配置
# ============================================

set -e

echo "=========================================="
echo "Noda Ops 服务容器启动"
echo "=========================================="

# 创建日志目录
mkdir -p /tmp/supervisor /var/log/noda-backup /app/history
touch /tmp/supervisor/cron.log /tmp/supervisor/cloudflared.log

# 加载环境变量
if [ -f /app/.env.ops ]; then
  set -a
  source /app/.env.ops
  set +a
  echo "✓ 已加载配置文件"
fi

# 验证备份系统环境变量
if [ -n "$POSTGRES_HOST" ] && [ -n "$B2_ACCOUNT_ID" ]; then
  echo "✓ 备份系统配置验证通过"

  # 创建必需的目录
  mkdir -p "${BACKUP_DIR:-/tmp/postgres_backups}"
  mkdir -p /app/history

  # 配置 rclone
  mkdir -p /home/nodaops/.config/rclone
  export RCLONE_CONFIG=/home/nodaops/.config/rclone/rclone.conf
  cat > /home/nodaops/.config/rclone/rclone.conf <<EOF
[b2remote]
type = b2
account = $B2_ACCOUNT_ID
key = $B2_APPLICATION_KEY
bucket = $B2_BUCKET_NAME
EOF
  echo "✓ rclone 配置完成"
else
  echo "⚠ 备份系统配置不完整，部分功能可能不可用"
fi

# 验证 Cloudflare Tunnel
if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  echo "✓ Cloudflare Tunnel 配置验证通过"
else
  echo "⚠ CLOUDFLARE_TUNNEL_TOKEN 未配置，隧道功能将禁用"
  # 将 supervisord.conf 复制到可写路径并禁用 cloudflared
  cp /etc/supervisord.conf /tmp/supervisord.conf
  sed -i 's/autostart=true/autostart=false/' /tmp/supervisord.conf 2>/dev/null || true
fi

# 显示定时任务
echo ""
echo "已配置的定时任务:"
crontab -l 2>/dev/null || echo "无定时任务"
echo ""

echo "=========================================="
echo "启动 supervisord..."
echo "=========================================="

# 启动 supervisord（如果 cloudflared 被禁用，使用修改后的配置）
SUPERVISOR_CONF="/etc/supervisord.conf"
if [ -f /tmp/supervisord.conf ]; then
  SUPERVISOR_CONF="/tmp/supervisord.conf"
fi
exec /usr/bin/supervisord -c "$SUPERVISOR_CONF"
