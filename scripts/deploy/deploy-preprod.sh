#!/bin/bash
set -euo pipefail

# ============================================
# Pre-prod 部署脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

# 设置 pre-prod 环境
export NODA_ENVIRONMENT=preprod
export SERVICE_NAME=noda-apps-preprod

# 部署流程
log_info "开始部署 pre-prod 环境..."

# 1. 拉取最新代码
log_info "拉取最新代码..."
git pull origin main

# 2. 构建镜像
log_info "构建镜像..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml build noda-apps-preprod

# 3. 启动服务
log_info "启动 pre-prod 服务..."
"$SCRIPT_DIR/../manage-containers.sh" start blue

# 4. 健康检查
log_info "执行健康检查..."
source "$SCRIPT_DIR/../lib/health.sh"
wait_container_healthy "noda-apps-preprod-blue" 300 || {
    log_error "健康检查失败"
    exit 1
}

# 5. 切换流量
log_info "切换流量到 pre-prod..."
"$SCRIPT_DIR/../manage-containers.sh" switch blue

log_success "Pre-prod 部署完成！"
