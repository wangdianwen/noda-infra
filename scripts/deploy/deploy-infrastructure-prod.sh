#!/bin/bash
set -euo pipefail

# ============================================
# 基础设施部署脚本（生产环境）
# ============================================
# 功能：自动部署并配置基础设施服务
# 包括：PostgreSQL (Prod/Dev), Keycloak, Nginx, Noda-Ops, Findclass-SSR
# ============================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# 注意：此变量故意不加引号使用，依赖 word splitting 拆分为多个 -f 参数
COMPOSE_FILES="-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml"

EXPECTED_CONTAINERS=(
  "noda-infra-postgres-prod"
  "noda-infra-postgres-dev"
  "noda-infra-keycloak-prod"
  "noda-infra-nginx"
  "noda-ops"
  "findclass-ssr"
)

# 启动的服务列表（findclass-ssr 需要单独启动，来自 docker-compose.app.yml）
START_SERVICES="postgres keycloak nginx noda-ops postgres-dev"

# ============================================
# 步骤 1/5: 验证环境
# ============================================
log_info "=========================================="
log_info "步骤 1/5: 验证环境配置"
log_info "=========================================="

if [ ! -f "config/secrets.sops.yaml" ]; then
  log_error "加密配置文件不存在: config/secrets.sops.yaml"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker 未安装"
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  log_error "Docker Compose 未安装"
  exit 1
fi

log_success "环境验证通过"

# ============================================
# 步骤 2/5: 重启容器
# ============================================
log_info "=========================================="
log_info "步骤 2/5: 重启容器"
log_info "=========================================="

log_info "停止现有容器..."
docker compose $COMPOSE_FILES down

log_info "启动 PostgreSQL, Keycloak, Nginx, Noda-Ops, PostgreSQL-Dev, Findclass-SSR..."
docker compose $COMPOSE_FILES up -d $START_SERVICES findclass-ssr

log_success "容器已启动"

# ============================================
# 步骤 3/5: 等待所有服务健康 + 初始化数据库
# ============================================
log_info "=========================================="
log_info "步骤 3/5: 等待所有服务健康"
log_info "=========================================="

HEALTH_TIMEOUT=90

for container in "${EXPECTED_CONTAINERS[@]}"; do
  WAITED=0
  while [ $WAITED -lt $HEALTH_TIMEOUT ]; do
    INSPECT=$(docker inspect --format='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "missing|missing")
    # bash 内置参数展开，避免子进程
    C_STATUS="${INSPECT%%|*}"
    C_HEALTH="${INSPECT##*|}"

    case "$C_STATUS" in
      running)
        case "$C_HEALTH" in
          healthy)
            log_success "$container — healthy"
            break
            ;;
          unhealthy)
            log_error "$container — unhealthy"
            docker logs "$container" --tail 10 2>&1 | sed 's/^/  /'
            exit 1
            ;;
          starting)
            sleep 3
            WAITED=$((WAITED + 3))
            ;;
          none)
            log_success "$container — 运行中"
            break
            ;;
        esac
        ;;
      missing)
        log_error "$container 不存在"
        docker logs "$container" --tail 10 2>&1 | sed 's/^/  /' || true
        exit 1
        ;;
      exited|dead)
        log_error "$container 状态异常: $C_STATUS"
        docker logs "$container" --tail 10 2>&1 | sed 's/^/  /'
        exit 1
        ;;
      *)
        sleep 3
        WAITED=$((WAITED + 3))
        ;;
    esac
  done

  if [ $WAITED -ge $HEALTH_TIMEOUT ]; then
    log_error "$container — 健康检查超时（${HEALTH_TIMEOUT}s）"
    docker logs "$container" --tail 15 2>&1 | sed 's/^/  /'
    exit 1
  fi
done

# 容器健康后初始化数据库
log_info "初始化数据库..."
if ! bash scripts/init-databases.sh; then
  log_error "数据库初始化失败"
  exit 1
fi
log_success "数据库初始化完成"

# ============================================
# 步骤 4/5: 配置 Keycloak
# ============================================
log_info "=========================================="
log_info "步骤 4/5: 配置 Keycloak"
log_info "=========================================="

log_info "配置 realm, client 和 Google OAuth..."
if ! bash scripts/setup-keycloak-full.sh; then
  log_error "Keycloak 配置失败"
  exit 1
fi
log_success "Keycloak 配置完成"

# ============================================
# 步骤 5/5: 最终验证（重启次数）
# ============================================
log_info "=========================================="
log_info "步骤 5/5: 最终验证"
log_info "=========================================="

RESTART_ISSUES=0
for container in "${EXPECTED_CONTAINERS[@]}"; do
  RESTARTS=$(docker inspect --format='{{.RestartCount}}' "$container" 2>/dev/null || echo "0")
  if [ "$RESTARTS" -gt 10 ]; then
    log_error "$container — 已重启 ${RESTARTS} 次，可能存在异常"
    docker logs "$container" --tail 5 2>&1 | sed 's/^/  /'
    RESTART_ISSUES=$((RESTART_ISSUES + 1))
  elif [ "$RESTARTS" -gt 3 ]; then
    log_info "$container — 重启 ${RESTARTS} 次（启动期正常行为）"
  fi
done

if [ $RESTART_ISSUES -gt 0 ]; then
  log_error "$RESTART_ISSUES 个容器频繁重启，请检查日志"
  exit 1
fi

log_success "所有容器验证通过"

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "基础设施部署完成！"
log_success "=========================================="
log_info "✓ PostgreSQL (Prod): 运行中"
log_info "✓ PostgreSQL (Dev): 运行中"
log_info "✓ Keycloak: 运行中（已配置 realm 和 Google OAuth）"
log_info "✓ Nginx: 运行中"
log_info "✓ Noda-Ops: 运行中"
log_info "✓ Findclass-SSR: 运行中"
log_info ""
log_info "访问地址："
log_info "  管理控制台: https://auth.noda.co.nz/admin"
log_info "  Realm 端点: https://auth.noda.co.nz/realms/noda"
log_success "=========================================="
