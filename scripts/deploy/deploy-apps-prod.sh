#!/bin/bash
# ============================================
# 部署应用服务到生产环境
# findclass-ssr: 重新构建镜像 + 部署
# ============================================

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# 注意：此变量故意不加引号使用，依赖 word splitting 拆分为多个 -f 参数
COMPOSE_FILES="-f docker/docker-compose.yml -f docker/docker-compose.prod.yml -f docker/docker-compose.dev.yml"

# 回滚目录和文件
ROLLBACK_DIR="/tmp/noda-rollback"
ROLLBACK_FILE="$ROLLBACK_DIR/images-apps-$(date +%s).txt"
ROLLBACK_COMPOSE="$ROLLBACK_DIR/docker-compose.app-rollback.yml"

# ============================================
# 镜像回滚函数 (D-05)
# ============================================

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

# 容器名到服务名映射（兼容 bash 3.2）
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

  log_info "回滚 findclass-ssr 到镜像 ${image_id:0:12}..."

  # 使用 docker tag + recreate 回滚到之前保存的镜像
  local rollback_tag="noda-rollback/findclass-ssr:$(date +%s)"
  docker tag "$image_id" "$rollback_tag" 2>/dev/null || true

  if ! docker compose $COMPOSE_FILES up -d --no-deps --force-recreate findclass-ssr; then
    log_error "findclass-ssr 回滚失败"
    return 1
  fi

  log_success "findclass-ssr 已回滚"
  return 0
}

# ============================================
# 步骤 1/5: 验证基础设施
# ============================================
log_info "=========================================="
log_info "步骤 1/5: 验证基础设施服务"
log_info "=========================================="

bash scripts/verify/verify-infrastructure.sh

# ============================================
# 步骤 2/5: 保存当前镜像标签
# ============================================
log_info "=========================================="
log_info "步骤 2/5: 保存当前镜像标签"
log_info "=========================================="

save_app_image_tags

# ============================================
# 步骤 3/5: 构建新镜像
# ============================================
log_info "=========================================="
log_info "步骤 3/5: 构建 findclass-ssr 镜像"
log_info "=========================================="

docker compose $COMPOSE_FILES build findclass-ssr
log_success "镜像构建完成"

# ============================================
# 步骤 4/5: 部署新版本
# ============================================
log_info "=========================================="
log_info "步骤 4/5: 部署新版本"
log_info "=========================================="

docker compose $COMPOSE_FILES up -d --no-deps --force-recreate findclass-ssr

# ============================================
# 步骤 5/5: 等待健康检查
# ============================================
log_info "=========================================="
log_info "步骤 5/5: 等待健康检查"
log_info "=========================================="

HEALTH_TIMEOUT=90
WAITED=0
while [ $WAITED -lt $HEALTH_TIMEOUT ]; do
  INSPECT=$(docker inspect --format='{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' findclass-ssr 2>/dev/null || echo "missing|missing")
  C_STATUS="${INSPECT%%|*}"
  C_HEALTH="${INSPECT##*|}"

  case "$C_STATUS" in
    running)
      case "$C_HEALTH" in
        healthy)
          log_success "findclass-ssr — healthy"
          break
          ;;
        unhealthy)
          log_error "findclass-ssr — unhealthy"
          docker logs findclass-ssr --tail 15 2>&1 | sed 's/^/  /'
          log_info "尝试回滚到上一版本..."
          rollback_app || true
          exit 1
          ;;
        starting)
          sleep 3
          WAITED=$((WAITED + 3))
          ;;
        none)
          log_success "findclass-ssr — 运行中"
          break
          ;;
      esac
      ;;
    missing)
      log_error "findclass-ssr 不存在"
      exit 1
      ;;
    exited|dead)
      log_error "findclass-ssr 状态异常: $C_STATUS"
      docker logs findclass-ssr --tail 15 2>&1 | sed 's/^/  /'
      log_info "尝试回滚到上一版本..."
      rollback_app || true
      exit 1
      ;;
    *)
      sleep 3
      WAITED=$((WAITED + 3))
      ;;
  esac
done

if [ $WAITED -ge $HEALTH_TIMEOUT ]; then
  log_error "findclass-ssr — 健康检查超时（${HEALTH_TIMEOUT}s）"
  docker logs findclass-ssr --tail 15 2>&1 | sed 's/^/  /'
  log_info "尝试回滚到上一版本..."
  rollback_app || true
  exit 1
fi

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "应用部署完成！"
log_success "=========================================="
log_info "回滚文件: ${ROLLBACK_FILE}（部署成功，可安全忽略）"
