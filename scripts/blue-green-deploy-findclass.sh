#!/bin/bash
set -euo pipefail

# ============================================
# findclass-ssr 蓝绿部署 wrapper
# ============================================
# 向后兼容入口，设置 findclass-ssr 专属参数后调用统一蓝绿部署脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# findclass-ssr 专属参数（per D-01, D-02）
export IMAGE_SOURCE="${IMAGE_SOURCE:-build}"
export CLEANUP_METHOD="${CLEANUP_METHOD:-tag-count}"
export CLEANUP_IMAGE_NAME="${CLEANUP_IMAGE_NAME:-findclass-ssr}"
export CLEANUP_KEEP_COUNT="${CLEANUP_KEEP_COUNT:-5}"
export COMPOSE_FILE="${COMPOSE_FILE:-$SCRIPT_DIR/../docker/docker-compose.app.yml}"

# findclass-ssr 使用 manage-containers.sh 默认值：
# SERVICE_NAME=findclass-ssr, SERVICE_PORT=3001, HEALTH_PATH=/api/health
# 无需额外覆盖

exec "$SCRIPT_DIR/blue-green-deploy.sh" "$@"
