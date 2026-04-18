#!/bin/bash
set -euo pipefail
# ============================================
# findclass-ssr 紧急回滚 wrapper
# ============================================
# 向后兼容入口，设置 findclass-ssr 专属参数后调用统一回滚脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# findclass-ssr 使用 manage-containers.sh 默认值：
# SERVICE_NAME=findclass-ssr, SERVICE_PORT=3001, HEALTH_PATH=/api/health
# 无需额外覆盖

exec "$SCRIPT_DIR/rollback-deploy.sh" "$@"
