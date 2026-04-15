#!/bin/bash
set -euo pipefail

# ============================================
# 紧急回滚脚本
# ============================================
# 功能：一键将流量切回上一个活跃环境的容器
# 用途：蓝绿部署后发现问题时，快速恢复到旧版本
# 注意：回滚脚本独立运行，不依赖 blue-green-deploy.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/manage-containers.sh"

# ============================================
# 函数: http_health_check（独立定义，回滚场景专用）
# ============================================
# 通过 docker exec 在目标容器内执行 wget 检测 HTTP 端点
# 回滚场景参数更激进：默认 10 次 x 3 秒 = 30 秒
# 参数:
#   $1: 容器名
#   $2: 最大重试次数（默认 10）
#   $3: 重试间隔秒数（默认 3）
# 返回：0=健康，1=失败
http_health_check() {
  local container="$1"
  local max_retries="${2:-10}"
  local interval="${3:-3}"
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
# 函数: e2e_verify（独立定义，回滚场景专用）
# ============================================
# 通过 nginx 容器 curl 目标容器，验证完整请求链路
# 参数:
#   $1: 目标环境 (blue 或 green)
#   $2: 最大重试次数（默认 5）
#   $3: 重试间隔秒数（默认 2）
# 返回：0=验证通过，1=验证失败
e2e_verify() {
  local target_env="$1"
  local max_retries="${2:-5}"
  local interval="${3:-2}"
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
# 主函数
# ============================================
main() {
  local active_env
  active_env=$(get_active_env)

  # 回滚目标 = 非活跃环境
  local rollback_env
  if [ "$active_env" = "blue" ]; then
    rollback_env="green"
  else
    rollback_env="blue"
  fi

  local rollback_container
  rollback_container=$(get_container_name "$rollback_env")

  log_info "=========================================="
  log_info "紧急回滚"
  log_info "=========================================="
  log_info "当前活跃: $active_env ($(get_container_name "$active_env"))"
  log_info "回滚目标: $rollback_env ($rollback_container)"
  log_info ""

  # 前置检查：nginx 容器
  if [ "$(is_container_running "$NGINX_CONTAINER")" != "true" ]; then
    log_error "nginx 容器 ($NGINX_CONTAINER) 未运行，无法回滚"
    exit 1
  fi

  # 检查回滚目标容器
  if [ "$(is_container_running "$rollback_container")" != "true" ]; then
    log_error "回滚目标容器 $rollback_container 未运行"
    log_error "无法回滚 — 请手动启动旧容器或修复新版本"
    log_info "当前活跃容器 $(get_container_name "$active_env") 状态:"
    docker inspect --format='运行: {{.State.Running}} 健康: {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$(get_container_name "$active_env")" 2>/dev/null || echo "  检查失败"
    exit 1
  fi

  # 步骤 1/4: 验证回滚目标容器健康
  log_info "步骤 1/4: 验证回滚目标容器健康"

  if ! http_health_check "$rollback_container" 10 3; then
    log_error "回滚目标容器 $rollback_container 不健康，拒绝回滚"
    log_error "请手动检查容器状态: docker logs $rollback_container --tail 50"
    exit 1
  fi

  # 步骤 2/4: 切换流量
  log_info "步骤 2/4: 切换流量 $active_env -> $rollback_env"

  update_upstream "$rollback_env"

  if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败，恢复 upstream"
    update_upstream "$active_env"
    exit 1
  fi

  reload_nginx
  set_active_env "$rollback_env"

  # 步骤 3/4: E2E 验证
  log_info "步骤 3/4: E2E 验证"

  if ! e2e_verify "$rollback_env"; then
    log_error "回滚后 E2E 验证失败"
    log_error "流量已切换到 $rollback_env，请手动检查服务状态"
    exit 1
  fi

  # 步骤 4/4: 完成
  log_info "步骤 4/4: 完成"
  log_success "=========================================="
  log_success "回滚完成"
  log_success "=========================================="
  log_success "$active_env -> $rollback_env"
  log_info ""
  log_info "新版本容器 $(get_container_name "$active_env") 仍在运行"
  log_info "确认无误后可手动停止: docker stop -t 30 $(get_container_name "$active_env")"
}

main "$@"
