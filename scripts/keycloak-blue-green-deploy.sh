#!/bin/bash
set -euo pipefail

# ============================================
# Keycloak 蓝绿部署脚本
# ============================================
# 功能：Keycloak 官方镜像的零停机蓝绿部署
# 步骤：Pull Image -> Stop Old -> Start New -> Health Check -> Switch -> E2E Verify -> Cleanup
# 用途：手动部署或由 Jenkinsfile.keycloak 调用
# 依赖：scripts/manage-containers.sh（参数化复用）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"

# 加载 .env（envsubst 需要 POSTGRES_USER 等环境变量）
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

source "$PROJECT_ROOT/scripts/manage-containers.sh"

# ============================================
# Keycloak 蓝绿参数（覆盖 manage-containers.sh 默认值）
# ============================================
export SERVICE_NAME="${SERVICE_NAME:-keycloak}"
export SERVICE_PORT="${SERVICE_PORT:-8080}"
export UPSTREAM_NAME="${UPSTREAM_NAME:-keycloak_backend}"
export HEALTH_PATH="${HEALTH_PATH:-/health/ready}"
export ACTIVE_ENV_FILE="${ACTIVE_ENV_FILE:-/opt/noda/active-env-keycloak}"
export UPSTREAM_CONF="${UPSTREAM_CONF:-$PROJECT_ROOT/config/nginx/snippets/upstream-keycloak.conf}"
export SERVICE_GROUP="${SERVICE_GROUP:-infra}"

# Keycloak 容器安全参数（覆盖 run_container 默认值）
export CONTAINER_MEMORY="${CONTAINER_MEMORY:-1g}"
export CONTAINER_MEMORY_RESERVATION="${CONTAINER_MEMORY_RESERVATION:-512m}"
export CONTAINER_READONLY="${CONTAINER_READONLY:-false}"
export CONTAINER_CMD="${CONTAINER_CMD:-start}"

# Keycloak 额外 docker run 参数（主题卷挂载 + data tmpfs）
export EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:--v $PROJECT_ROOT/docker/services/keycloak/themes:/opt/keycloak/themes/noda:ro --tmpfs /opt/keycloak/data}"

# envsubst 变量列表（Keycloak 需要替换的变量比 findclass-ssr 多）
export ENVSUBST_VARS='${POSTGRES_USER} ${POSTGRES_PASSWORD} ${KEYCLOAK_ADMIN_USER} ${KEYCLOAK_ADMIN_PASSWORD} ${SMTP_HOST} ${SMTP_PORT} ${SMTP_FROM} ${SMTP_USER} ${SMTP_PASSWORD}'

# 镜像配置
KEYCLOAK_IMAGE="${KEYCLOAK_IMAGE:-quay.io/keycloak/keycloak:26.2.3}"

# 健康检查参数（Keycloak 启动较慢）
HEALTH_CHECK_MAX_RETRIES=45
HEALTH_CHECK_INTERVAL=4
E2E_MAX_RETRIES=5
E2E_INTERVAL=2

# ============================================
# 函数: http_health_check
# ============================================
# Keycloak 专用 HTTP 健康检查（per D-01）
# 使用 /health/ready 端点
http_health_check() {
  local container="$1"
  local max_retries="${2:-$HEALTH_CHECK_MAX_RETRIES}"
  local interval="${3:-$HEALTH_CHECK_INTERVAL}"
  local attempt=0

  log_info "Keycloak HTTP 健康检查: $container (最多 ${max_retries} 次, 间隔 ${interval}s)"

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    if docker exec "$container" wget --quiet --tries=1 --spider "http://localhost:${SERVICE_PORT}${HEALTH_PATH}" 2>/dev/null; then
      log_success "$container — Keycloak 健康检查通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      sleep "$interval"
    fi
  done

  log_error "$container — Keycloak 健康检查失败 (${max_retries} 次尝试)"
  log_info "最近容器日志:"
  docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
  return 1
}

# ============================================
# 函数: e2e_verify
# ============================================
# 通过 nginx 容器验证 Keycloak 可达性
e2e_verify() {
  local target_env="$1"
  local max_retries="${2:-$E2E_MAX_RETRIES}"
  local interval="${3:-$E2E_INTERVAL}"
  local container_name
  container_name=$(get_container_name "$target_env")

  log_info "E2E 验证: nginx -> $container_name (最多 ${max_retries} 次)"

  local use_curl=true
  if ! docker exec "$NGINX_CONTAINER" which curl >/dev/null 2>&1; then
    log_info "nginx 容器无 curl，使用 wget 备选方案"
    use_curl=false
  fi

  local attempt=0
  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    local result=1

    if [ "$use_curl" = true ]; then
      local http_code
      http_code=$(docker exec "$NGINX_CONTAINER" \
        curl -s -o /dev/null -w "%{http_code}" \
        "http://${container_name}:${SERVICE_PORT}${HEALTH_PATH}" 2>/dev/null || echo "000")

      if [ "$http_code" = "200" ]; then
        result=0
      fi
    else
      if docker exec "$NGINX_CONTAINER" \
        wget --quiet --tries=1 --spider \
        "http://${container_name}:${SERVICE_PORT}${HEALTH_PATH}" 2>/dev/null; then
        result=0
      fi
    fi

    if [ $result -eq 0 ]; then
      log_success "E2E 验证通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      sleep "$interval"
    fi
  done

  log_error "E2E 验证失败 (${max_retries} 次尝试)"
  return 1
}

# ============================================
# 函数: cleanup_old_keycloak_images
# ============================================
# 清理无标签的 Keycloak 镜像（官方镜像不使用 Git SHA 标签）
cleanup_old_keycloak_images() {
  local deleted=0

  # 清理 dangling images
  local dangling_ids
  dangling_ids=$(docker images -f "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
  for img_id in $dangling_ids; do
    docker rmi "$img_id" 2>/dev/null || true
    deleted=$((deleted + 1))
  done

  if [ "$deleted" -gt 0 ]; then
    log_success "镜像清理完成: 删除 ${deleted} 个 dangling 镜像"
  else
    log_info "镜像清理: 无需清理"
  fi
}

# ============================================
# 主函数
# ============================================
main() {
  log_info "=========================================="
  log_info "Keycloak 蓝绿部署开始"
  log_info "=========================================="

  # 前置检查
  log_info "前置检查..."

  if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon 不可用"
    exit 1
  fi

  if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
    log_error "nginx 容器 ($NGINX_CONTAINER) 未运行"
    exit 1
  fi

  if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log_error "Docker 网络 $NETWORK_NAME 不存在"
    exit 1
  fi

  # 读取活跃环境
  local active_env target_env
  active_env=$(get_active_env)
  target_env=$(get_inactive_env)
  local target_container
  target_container=$(get_container_name "$target_env")

  # 检测并停止 compose 管理的旧容器（首次蓝绿部署迁移）
  local compose_container="noda-infra-keycloak-prod"
  if [ "$(is_container_running "$compose_container")" = "true" ]; then
    log_warn "检测到 compose 管理的 Keycloak 容器: $compose_container"
    log_info "停止 compose 容器（迁移到蓝绿架构）..."
    docker stop -t 30 "$compose_container"
    docker rm "$compose_container"
    log_success "compose 容器已停止并移除"
  fi

  log_info "活跃环境: $active_env"
  log_info "目标环境: $target_env"
  log_info "目标容器: $target_container"
  log_info "镜像: $KEYCLOAK_IMAGE"

  # 步骤 1/7: 拉取镜像
  log_info "=========================================="
  log_info "步骤 1/7: 拉取 Keycloak 镜像"
  log_info "=========================================="

  docker pull "$KEYCLOAK_IMAGE"
  log_success "镜像拉取完成: $KEYCLOAK_IMAGE"

  # 步骤 2/7: 停止旧目标容器 + 启动新容器
  log_info "=========================================="
  log_info "步骤 2/7: 停止旧目标容器 + 启动新容器"
  log_info "=========================================="

  if [ "$(is_container_running "$target_container")" = "true" ]; then
    log_info "停止旧目标容器: $target_container"
    docker stop -t 30 "$target_container"
    docker rm "$target_container"
    log_success "旧目标容器已停止"
  fi

  run_container "$target_env" "$KEYCLOAK_IMAGE"

  # 步骤 3/7: HTTP 健康检查
  log_info "=========================================="
  log_info "步骤 3/7: HTTP 健康检查"
  log_info "=========================================="

  if ! http_health_check "$target_container" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
    log_error "健康检查失败，保持当前环境: $active_env"
    log_warn "新容器 $target_container 仍在运行，可手动检查后停止"
    exit 1
  fi

  # 步骤 4/7: 切换流量
  log_info "=========================================="
  log_info "步骤 4/7: 切换流量 $active_env -> $target_env"
  log_info "=========================================="

  update_upstream "$target_env"

  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败，回滚 upstream"
    update_upstream "$active_env"
    exit 1
  fi

  reload_nginx
  set_active_env "$target_env"
  log_success "流量切换完成: $active_env -> $target_env"

  # 步骤 5/7: E2E 验证
  log_info "=========================================="
  log_info "步骤 5/7: E2E 验证"
  log_info "=========================================="

  if ! e2e_verify "$target_env" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"; then
    log_error "E2E 验证失败，执行自动回滚"
    update_upstream "$active_env"
    docker exec "$NGINX_CONTAINER" nginx -t
    reload_nginx
    set_active_env "$active_env"
    log_warn "已回滚到 $active_env，新容器 $target_container 仍在运行"
    exit 1
  fi

  # 步骤 6/7: 清理旧镜像
  log_info "=========================================="
  log_info "步骤 6/7: 清理旧镜像"
  log_info "=========================================="

  cleanup_old_keycloak_images

  # 完成
  log_success "=========================================="
  log_success "Keycloak 蓝绿部署完成"
  log_success "=========================================="
  log_success "$active_env -> $target_env (镜像: $KEYCLOAK_IMAGE)"
}

main "$@"
