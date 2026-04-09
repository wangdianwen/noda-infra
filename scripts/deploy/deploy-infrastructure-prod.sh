#!/bin/bash
set -euo pipefail

# ============================================
# 基础设施部署脚本（生产环境）
# ============================================
# 功能：自动部署并配置基础设施服务
# 包括：PostgreSQL, Keycloak, Nginx
# ============================================

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
  echo -e "${YELLOW}ℹ️  $*${NC}"
}

log_success() {
  echo -e "${GREEN}✅ $*${NC}"
}

log_error() {
  echo -e "${RED}❌ $*${NC}"
}

# ============================================
# 步骤 1: 验证环境
# ============================================
log_info "=========================================="
log_info "步骤 1/6: 验证环境配置"
log_info "=========================================="

if [ ! -f "config/secrets.sops.yaml" ]; then
  log_error "加密配置文件不存在: config/secrets.sops.yaml"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker 未安装"
  exit 1
fi

if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
  log_error "Docker Compose 未安装"
  exit 1
fi

log_success "环境验证通过"

# ============================================
# 步骤 2: 初始化数据库
# ============================================
log_info "=========================================="
log_info "步骤 2/6: 初始化数据库"
log_info "=========================================="

bash scripts/init-databases.sh

if [ $? -eq 0 ]; then
  log_success "数据库初始化完成"
else
  log_error "数据库初始化失败"
  exit 1
fi

# ============================================
# 步骤 3: 停止现有容器
# ============================================
log_info "=========================================="
log_info "步骤 3/6: 停止现有容器"
log_info "=========================================="

log_info "停止现有基础设施容器..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml down

log_success "容器已停止"

# ============================================
# 步骤 4: 启动基础设施服务
# ============================================
log_info "=========================================="
log_info "步骤 4/6: 启动基础设施服务"
log_info "=========================================="

log_info "启动 PostgreSQL, Keycloak, Nginx..."
docker compose -f docker/docker-compose.yml -f docker/docker-compose.prod.yml up -d postgres keycloak nginx

log_success "基础设施服务已启动"

# ============================================
# 步骤 5: 等待服务启动
# ============================================
log_info "=========================================="
log_info "步骤 5/6: 等待服务启动"
log_info "=========================================="

log_info "等待 PostgreSQL 启动..."
MAX_WAIT=30
WAIT_TIME=0
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
  if docker exec noda-infra-postgres-1 pg_isready -U postgres >/dev/null 2>&1; then
    log_success "PostgreSQL 已就绪"
    break
  fi
  sleep 2
  WAIT_TIME=$((WAIT_TIME + 2))
done

if [ $WAIT_TIME -ge $MAX_WAIT ]; then
  log_error "PostgreSQL 启动超时"
  exit 1
fi

log_info "等待 Keycloak 启动..."
MAX_WAIT=60
WAIT_TIME=0
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
  if docker ps --format "{{.Names}}" | grep -q "noda-infra-keycloak-1"; then
    if docker logs noda-infra-keycloak-1 2>&1 | grep -q "Keycloak.*started"; then
      log_success "Keycloak 已启动"
      break
    fi
  fi

  if [ $WAIT_TIME -eq $((MAX_WAIT - 5)) ]; then
    log_error "Keycloak 启动超时"
    docker logs noda-infra-keycloak-1 --tail 30
    exit 1
  fi

  echo "等待中... (${WAIT_TIME}s/${MAX_WAIT}s)"
  sleep 5
  WAIT_TIME=$((WAIT_TIME + 5))
done

# ============================================
# 步骤 6: 配置 Keycloak
# ============================================
log_info "=========================================="
log_info "步骤 6/6: 配置 Keycloak"
log_info "=========================================="

log_info "配置 realm, client 和 Google OAuth..."
bash scripts/setup-keycloak-full.sh

if [ $? -eq 0 ]; then
  log_success "Keycloak 配置完成"
else
  log_error "Keycloak 配置失败"
  exit 1
fi

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "基础设施部署完成！"
log_success "=========================================="
log_info "✓ PostgreSQL: 运行中"
log_info "✓ Keycloak: 运行中（已配置 realm 和 Google OAuth）"
log_info "✓ Nginx: 运行中"
log_info ""
log_info "访问地址："
log_info "  管理控制台: https://auth.noda.co.nz/admin"
log_info "  Realm 端点: https://auth.noda.co.nz/realms/noda"
log_success "=========================================="
