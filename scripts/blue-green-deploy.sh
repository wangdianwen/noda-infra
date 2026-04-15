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

# ============================================
# 常量
# ============================================
HEALTH_CHECK_MAX_RETRIES=30
HEALTH_CHECK_INTERVAL=4
E2E_MAX_RETRIES=5
E2E_INTERVAL=2
COMPOSE_FILE="$PROJECT_ROOT/docker/docker-compose.app.yml"

# ============================================
# 函数: http_health_check
# ============================================
# 通过 docker exec 在目标容器内执行 wget 检测 HTTP 端点
# 参数:
#   $1: 容器名
#   $2: 最大重试次数（默认 30）
#   $3: 重试间隔秒数（默认 4）
# 返回：0=健康，1=失败
http_health_check() {
  local container="$1"
  local max_retries="${2:-$HEALTH_CHECK_MAX_RETRIES}"
  local interval="${3:-$HEALTH_CHECK_INTERVAL}"
  local attempt=0

  log_info "HTTP 健康检查: $container (最多 ${max_retries} 次, 间隔 ${interval}s)"

  while [ $attempt -lt $max_retries ]; do
    attempt=$((attempt + 1))

    if docker exec "$container" wget --quiet --tries=1 --spider "http://localhost:3001/api/health" 2>/dev/null; then
      log_success "$container — HTTP 健康检查通过 (第 ${attempt}/${max_retries} 次)"
      return 0
    fi

    if [ $attempt -lt $max_retries ]; then
      sleep "$interval"
    fi
  done

  log_error "$container — HTTP 健康检查失败 (${max_retries} 次尝试)"
  log_info "最近容器日志:"
  docker logs "$container" --tail 20 2>&1 | sed 's/^/  /'
  return 1
}

# ============================================
# 函数: e2e_verify
# ============================================
# 通过 nginx 容器 curl 目标容器，验证完整请求链路
# 参数:
#   $1: 目标环境 (blue 或 green)
#   $2: 最大重试次数（默认 5）
#   $3: 重试间隔秒数（默认 2）
# 返回：0=验证通过，1=验证失败
e2e_verify() {
  local target_env="$1"
  local max_retries="${2:-$E2E_MAX_RETRIES}"
  local interval="${3:-$E2E_INTERVAL}"
  local container_name
  container_name=$(get_container_name "$target_env")

  log_info "E2E 验证: nginx -> $container_name (最多 ${max_retries} 次)"

  # 检测 nginx 容器是否有 curl
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
        "http://${container_name}:3001/api/health" 2>/dev/null || echo "000")

      if [ "$http_code" = "200" ]; then
        result=0
      fi
    else
      if docker exec "$NGINX_CONTAINER" \
        wget --quiet --tries=1 --spider \
        "http://${container_name}:3001/api/health" 2>/dev/null; then
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

  if ! http_health_check "$target_container" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
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

  if ! e2e_verify "$target_env" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"; then
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
