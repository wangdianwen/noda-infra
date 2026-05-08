#!/bin/bash
set -euo pipefail

# ============================================
# Pre-prod 流量切换脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# 设置环境
export NODA_ENVIRONMENT=preprod
export SERVICE_NAME=noda-apps-preprod

log_info "切换 pre-prod 流量..."

# 执行切换
"$SCRIPT_DIR/manage-containers.sh" switch blue

# 验证切换
source "$SCRIPT_DIR/lib/health.sh"
wait_container_healthy "noda-apps-preprod-blue" 300 || {
    log_error "健康检查失败，切换失败"
    exit 1
}

log_success "Pre-prod 流量切换完成！"
