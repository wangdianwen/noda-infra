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

# 创建日志和运行目录
mkdir -p /tmp/supervisor /var/log/noda-backup /app/history
touch /var/log/noda-backup/cron.log /var/log/noda-backup/cloudflared.log

# 安装备份 crontab（2026-09-13 修复）：Dockerfile 把 deploy/crontab 烤在
# /etc/cron.d/nodaops，但 supervisord 启动的 BusyBox crond 只读
# /etc/crontabs/root——/etc/cron.d 从未被读取，每日备份静默不执行。
# 启动时复制到 BusyBox crond 的读取位置（覆盖 Alpine 默认 run-parts 条目，
# 那些周期目录本就是空的）
if [ -f /etc/cron.d/nodaops ]; then
  cp /etc/cron.d/nodaops /etc/crontabs/root
  echo "✓ 备份 crontab 已安装到 /etc/crontabs/root（BusyBox crond 读取位置）"
fi

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
  mkdir -p /home/nodaops/.config/rclone 2>/dev/null || {
    # tmpfs 挂载可能导致权限问题，尝试修复
    sudo mkdir -p /home/nodaops/.config/rclone 2>/dev/null || true
  }
  if [ ! -d /home/nodaops/.config/rclone ]; then
    echo "⚠ 无法创建 rclone 配置目录，B2 上传可能失败"
  fi
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
  # DNS 预热：等待 Cloudflare edge DNS 解析稳定
  echo "  等待 DNS 解析稳定..."
  for i in $(seq 1 10); do
    if nslookup region1.v2.argotunnel.com >/dev/null 2>&1; then
      EDGE_IP=$(nslookup region1.v2.argotunnel.com 2>/dev/null | grep -A1 'Name:' | grep 'Address' | awk '{print $2}')
      # 198.41.x.x 或 198.18.5.x 是正常 edge IP；198.18.0.x 是 WARP 地址，可能不稳定
      if echo "$EDGE_IP" | grep -qE '^198\.41\.|^198\.18\.[1-9]'; then
        echo "  ✓ DNS 解析正常: $EDGE_IP"
        break
      fi
    fi
    sleep 2
  done
else
  echo "⚠ CLOUDFLARE_TUNNEL_TOKEN 未配置，隧道功能将禁用"
  # 将 supervisord.conf 复制到可写路径并禁用 cloudflared
  cp /etc/supervisord.conf /tmp/supervisord.conf
  sed -i 's/autostart=true/autostart=false/' /tmp/supervisord.conf 2>/dev/null || true
fi

# 验证 Doppler 密钥备份配置
if [ -n "$DOPPLER_TOKEN" ]; then
  echo "✓ Doppler 密钥备份配置验证通过"
  if command -v doppler &>/dev/null; then
    echo "  Doppler CLI: $(doppler --version 2>/dev/null | head -1 || echo '未知版本')"
  fi
else
  echo "⚠ DOPPLER_TOKEN 未配置，密钥备份将禁用"
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
