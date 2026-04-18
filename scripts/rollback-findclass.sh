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
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"

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

  if ! http_health_check "$rollback_container" "3001" "/api/health" "10" "3"; then
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

  if ! e2e_verify "$rollback_env" "3001" "/api/health" "5" "2"; then
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
