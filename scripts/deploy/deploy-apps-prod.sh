#!/bin/bash
# 部署 noda-apps 分组到生产环境
# findclass-ssr: API + SSR 渲染 + 静态文件（三合一服务）

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# 回滚目录和文件
ROLLBACK_DIR="/tmp/noda-rollback"
ROLLBACK_FILE="$ROLLBACK_DIR/images-apps-$(date +%s).txt"
ROLLBACK_COMPOSE="$ROLLBACK_DIR/docker-compose.app-rollback.yml"

# ============================================
# 应用镜像回滚函数 (D-05)
# ============================================

# save_app_image_tags - 保存 findclass-ssr 当前镜像
save_app_image_tags() {
  mkdir -p "$ROLLBACK_DIR"
  : > "$ROLLBACK_FILE"
  local image_id
  image_id=$(docker inspect --format='{{.Image}}' findclass-ssr 2>/dev/null || echo "")
  if [ -n "$image_id" ]; then
    echo "findclass-ssr=${image_id}" >> "$ROLLBACK_FILE"
    log_info "已保存 findclass-ssr 镜像: ${image_id:0:12}..."
  fi
  log_success "应用镜像标签已保存"
}

# rollback_app - 使用 docker compose override 回退到上一版本 findclass-ssr
# 参数：无（从 ROLLBACK_FILE 读取镜像 digest）
# 返回：0=成功，1=失败
#
# 原理：生成临时 docker-compose.app-rollback.yml，将 findclass-ssr 的 image
# 设为保存的 digest，然后通过 docker compose -f app -f rollback up -d
# --no-deps --force-recreate 恢复，保留所有 compose 配置。
rollback_app() {
  if [ ! -f "$ROLLBACK_FILE" ]; then
    log_error "回滚文件不存在: ${ROLLBACK_FILE}"
    return 1
  fi

  local image_id
  image_id=$(grep "findclass-ssr=" "$ROLLBACK_FILE" | cut -d'=' -f2)
  if [ -z "$image_id" ]; then
    log_error "回滚文件中无 findclass-ssr 镜像信息"
    return 1
  fi

  log_info "生成回滚 compose override..."
  mkdir -p "$ROLLBACK_DIR"
  cat > "$ROLLBACK_COMPOSE" <<EOF
# 自动生成的应用回滚 overlay
name: noda-apps
services:
  findclass-ssr:
    image: ${image_id}
EOF

  log_info "回滚 findclass-ssr 到镜像 ${image_id:0:12}..."
  if ! docker compose -f docker/docker-compose.app.yml -f "$ROLLBACK_COMPOSE" up -d --no-deps --force-recreate findclass-ssr; then
    log_error "findclass-ssr 回滚失败"
    return 1
  fi

  log_success "findclass-ssr 已回滚（使用 compose override 恢复）"
  return 0
}

log_info "开始部署 noda-apps: $IMAGE_TAG"

# 1. 验证基础设施服务运行
log_info "验证基础设施服务..."
bash scripts/verify/verify-infrastructure.sh

# 1.5 保存当前镜像标签
save_app_image_tags

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

if [ $ELAPSED -ge $TIMEOUT ]; then
  log_error "应用启动超时（${TIMEOUT}s）"
  log_info "尝试回滚到上一版本..."
  rollback_app || true
  exit 1
fi

# 5. 验证应用状态
log_info "验证应用状态..."
docker compose -f docker/docker-compose.app.yml ps

log_info "回滚文件: ${ROLLBACK_FILE}（部署成功，可安全忽略）"
log_success "noda-apps 部署完成！"
