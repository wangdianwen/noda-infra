#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# Pre-prod 环境初始化脚本（Phase 56-01）
# ============================================
# 功能：创建 pre-prod 状态目录和 upstream 配置文件
# 用途：首次部署前运行，初始化 pre-prod 环境
# ============================================

log_info "初始化 Pre-prod 环境..."

# 创建状态目录
log_info "创建状态目录: /opt/noda/preprod"
sudo mkdir -p /opt/noda/preprod

# 创建 upstream 配置目录
log_info "创建 upstream 配置目录: /opt/noda/upstream"
sudo mkdir -p /opt/noda/upstream

# 创建状态文件（默认 blue）
log_info "创建状态文件: /opt/noda/preprod/active-env"
echo "blue" | sudo tee /opt/noda/preprod/active-env >/dev/null

# 记录镜像 SHA（首次部署时为空）
log_info "创建镜像记录文件"
echo "" | sudo tee /opt/noda/preprod/active-blue >/dev/null
echo "" | sudo tee /opt/noda/preprod/active-green >/dev/null

# 创建 upstream 配置文件（pre-prod）
log_info "创建 upstream 配置文件: /opt/noda/upstream/_preprod_upstream.conf"
cat << 'EOF' | sudo tee /opt/noda/upstream/_preprod_upstream.conf >/dev/null
# noda-apps upstream 变量 — preprod 环境
# 由 update-upstream.sh 在蓝绿切换时更新
set $findclass_upstream noda-apps-preprod-blue:3000;
set $www_upstream noda-apps-preprod-blue:3002;
set $auth_app_upstream noda-apps-preprod-blue:3004;
set $admin_upstream noda-apps-preprod-blue:3006;
set $admin_api_upstream noda-apps-preprod-blue:3011;
EOF

# 创建 upstream 配置文件（prod，如果不存在）
if [ ! -f /opt/noda/upstream/upstream.conf ]; then
    log_info "创建 upstream 配置文件: /opt/noda/upstream/upstream.conf"
    cat << 'EOF' | sudo tee /opt/noda/upstream/upstream.conf >/dev/null
# noda-apps upstream 变量 — prod 环境
# 由 update-upstream.sh 在蓝绿切换时更新
set $findclass_upstream noda-apps-blue:3000;
set $www_upstream noda-apps-blue:3002;
set $auth_app_upstream noda-apps-blue:3004;
set $admin_upstream noda-apps-blue:3006;
set $admin_api_upstream noda-apps-blue:3011;
EOF
fi

# 设置文件权限
log_info "设置文件权限..."
sudo chown -R jenkins:jenkins /opt/noda/preprod
sudo chown -R jenkins:jenkins /opt/noda/upstream
sudo chmod 644 /opt/noda/preprod/active-env
sudo chmod 644 /opt/noda/upstream/*.conf

log_success "Pre-prod 环境初始化完成"
log_info "状态文件: /opt/noda/preprod/active-env"
log_info "Upstream 配置: /opt/noda/upstream/_preprod_upstream.conf"
