#!/bin/bash
set -euo pipefail

# ============================================
# 蓝绿部署主脚本
# ============================================
# 功能：完整的零停机部署流程
# 步骤：构建 → SHA 标签 → 停旧目标 → 启动新 → HTTP 健康检查 → 切换流量 → E2E 验证 → 清理
# 用途：Phase 22 蓝绿部署核心脚本，Phase 23 Pipeline 将调用此脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"

# ============================================
# 常量
# ============================================
HEALTH_CHECK_MAX_RETRIES=30
HEALTH_CHECK_INTERVAL=4
E2E_MAX_RETRIES=5
E2E_INTERVAL=2
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.app.yml"

# ============================================
# 函数: cleanup_old_images
# ============================================
# 保留最近 N 个带标签的镜像，删除更早的
# 参数:
#   $1: 保留数量（默认 5）
cleanup_old_images() {
  local keep_count="${1:-5}"

  # 列出所有非 latest 标签的镜像，按创建时间排序（最新在前）
  local images
  images=$(docker images findclass-ssr --format '{{.Tag}} {{.CreatedAt}}' \
    | grep -v '^latest ' \
    | sort -t' ' -k2 -r \
    | awk '{print $1}')

  local total
  total=$(echo "$images" | grep -c . || true)

  if [ "$total" -le "$keep_count" ]; then
    log_info "镜像清理: ${total} 个标签镜像 <= 保留 ${keep_count}，无需清理"
    return 0
  fi

  local to_delete
  to_delete=$(echo "$images" | tail -n +$((keep_count + 1)))

  log_info "镜像清理: ${total} 个标签镜像，保留 ${keep_count}，删除 $((total - keep_count)) 个"

  for tag in $to_delete; do
    log_info "  删除 findclass-ssr:${tag}"
    docker rmi "findclass-ssr:${tag}" 2>/dev/null || true
  done

  log_success "旧镜像清理完成"
}

# ============================================
# 主函数
# ============================================
main() {
  local apps_dir="${1:-.}"

  # 前置检查
  log_info "=========================================="
  log_info "蓝绿部署开始"
  log_info "=========================================="

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

  log_info "活跃环境: $active_env"
  log_info "目标环境: $target_env"
  log_info "目标容器: $target_container"

  # 获取 Git SHA
  local short_sha
  short_sha=$(git -C "$apps_dir" rev-parse --short HEAD 2>/dev/null || true)
  if [ -z "$short_sha" ]; then
    log_error "无法获取 Git SHA（目录: $apps_dir），请确认在 git 仓库中执行"
    exit 1
  fi
  log_info "镜像标签: findclass-ssr:${short_sha}"

  # 步骤 1/7: 构建镜像
  log_info "=========================================="
  log_info "步骤 1/7: 构建镜像"
  log_info "=========================================="

  docker compose -f "$COMPOSE_FILE" build findclass-ssr
  log_success "镜像构建完成"

  # 步骤 2/7: 添加 SHA 标签
  log_info "=========================================="
  log_info "步骤 2/7: 标记镜像 findclass-ssr:${short_sha}"
  log_info "=========================================="

  docker tag findclass-ssr:latest "findclass-ssr:${short_sha}"
  log_success "镜像标签已添加: findclass-ssr:${short_sha}"

  # 步骤 3/7: 停止旧目标容器 + 启动新容器
  log_info "=========================================="
  log_info "步骤 3/7: 停止旧目标容器 + 启动新容器"
  log_info "=========================================="

  if [ "$(is_container_running "$target_container")" = "true" ]; then
    log_info "停止旧目标容器: $target_container"
    docker stop -t 30 "$target_container"
    docker rm "$target_container"
    log_success "旧目标容器已停止"
  fi

  run_container "$target_env" "findclass-ssr:${short_sha}"

  # 步骤 4/7: HTTP 健康检查
  log_info "=========================================="
  log_info "步骤 4/7: HTTP 健康检查"
  log_info "=========================================="

  if ! http_health_check "$target_container" "3001" "/api/health" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
    log_error "健康检查失败，保持当前环境: $active_env"
    log_warn "新容器 $target_container 仍在运行，可手动检查后停止"
    exit 1
  fi

  # 步骤 5/7: 切换流量
  log_info "=========================================="
  log_info "步骤 5/7: 切换流量 $active_env -> $target_env"
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

  # 步骤 6/7: E2E 验证
  log_info "=========================================="
  log_info "步骤 6/7: E2E 验证"
  log_info "=========================================="

  if ! e2e_verify "$target_env" "3001" "/api/health" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"; then
    log_error "E2E 验证失败，执行自动回滚"
    update_upstream "$active_env"
    docker exec "$NGINX_CONTAINER" nginx -t
    reload_nginx
    set_active_env "$active_env"
    log_warn "已回滚到 $active_env，新容器 $target_container 仍在运行"
    exit 1
  fi

  # 步骤 7/7: 清理旧镜像
  log_info "=========================================="
  log_info "步骤 7/7: 清理旧镜像"
  log_info "=========================================="

  cleanup_old_images 5

  # 完成
  log_success "=========================================="
  log_success "蓝绿部署完成"
  log_success "=========================================="
  log_success "$active_env -> $target_env (镜像: findclass-ssr:${short_sha})"
}

main "$@"
