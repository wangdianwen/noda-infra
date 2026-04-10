#!/bin/bash
# 部署 noda-apps 分组到生产环境
# findclass-ssr: API + SSR 渲染 + 静态文件（三合一服务）

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"

log_info "开始部署 noda-apps: $IMAGE_TAG"

# 1. 验证基础设施服务运行
log_info "验证基础设施服务..."
bash scripts/verify/verify-infrastructure.sh

# 2. 停止并删除现有应用容器
log_info "停止现有应用容器..."
docker compose -f docker/docker-compose.app.yml down 2>/dev/null || true
docker stop findclass-ssr 2>/dev/null || true
docker rm findclass-ssr 2>/dev/null || true

# 3. 启动新版本应用
log_info "启动新版本应用..."
docker compose -f docker/docker-compose.app.yml up -d --build

# 4. 等待应用就绪
log_info "等待应用启动..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
  if docker inspect findclass-ssr --format='{{.State.Status}}' 2>/dev/null | grep -q "running"; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

# 5. 验证应用状态
log_info "验证应用状态..."
docker compose -f docker/docker-compose.app.yml ps

log_success "noda-apps 部署完成！"
