#!/bin/bash
set -euo pipefail

# ============================================
# Keycloak 蓝绿部署 wrapper
# ============================================
# 向后兼容入口，设置 Keycloak 专属参数后调用统一蓝绿部署脚本
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
export SERVICE_GROUP="${SERVICE_GROUP:-infra}"

# Keycloak 容器安全参数
export CONTAINER_MEMORY="${CONTAINER_MEMORY:-1g}"
export CONTAINER_MEMORY_RESERVATION="${CONTAINER_MEMORY_RESERVATION:-512m}"
export CONTAINER_READONLY="${CONTAINER_READONLY:-false}"
export CONTAINER_CMD="${CONTAINER_CMD:-start}"

# Keycloak 镜像配置（per D-01）
export IMAGE_SOURCE="${IMAGE_SOURCE:-pull}"
export SERVICE_IMAGE="${SERVICE_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"

# 清理策略（per D-02）
export CLEANUP_METHOD="${CLEANUP_METHOD:-dangling}"

# 额外 docker run 参数
export EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:--v $PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data}"

# envsubst 变量列表
export ENVSUBST_VARS='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'

# 健康检查参数（Keycloak 启动较慢）
export HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-45}"
export HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"

# 容器健康检查命令
export CONTAINER_HEALTH_CMD="${CONTAINER_HEALTH_CMD:-bash -c 'echo > /dev/tcp/localhost/8080'}"

# Compose 迁移检查（仅 keycloak 需要）
export COMPOSE_MIGRATION_CONTAINER="${COMPOSE_MIGRATION_CONTAINER:-noda-infra-keycloak-prod}"

exec "$SCRIPT_DIR/blue-green-deploy.sh" "$@"
