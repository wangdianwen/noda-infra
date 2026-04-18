#!/bin/bash
set -euo pipefail
# ============================================
# Keycloak 紧急回滚 wrapper
# ============================================
# 向后兼容入口，设置 Keycloak 专属参数后调用统一回滚脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Keycloak 服务参数（覆盖 manage-containers.sh 默认值）
export SERVICE_NAME="${SERVICE_NAME:-keycloak}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"
export UPSTREAM_NAME="${UPSTREAM_NAME:-keycloak_backend}"
export HEALTH_PATH="${HEALTH_PATH:-/realms/master}"
export ACTIVE_ENV_FILE="${ACTIVE_ENV_FILE:-/opt/noda/active-env-keycloak}"
export UPSTREAM_CONF="${UPSTREAM_CONF:-$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf}"

exec "$SCRIPT_DIR/rollback-deploy.sh" "$@"
