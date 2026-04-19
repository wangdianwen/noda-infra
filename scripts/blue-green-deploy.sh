#!/bin/bash
set -euo pipefail

# ============================================
# 统一蓝绿部署脚本
# ============================================
# 功能：完整的零停机部署流程，通过环境变量参数化支持多服务
# 步骤：镜像获取 -> 停旧目标 -> 启动新 -> HTTP 健康检查 -> 切换流量 -> E2E 验证 -> 清理
# 参数化：
#   IMAGE_SOURCE:  build（docker compose build + tag）| pull（docker pull）| none（使用已有）
#   CLEANUP_METHOD: tag-count | dangling | none
# 用途：由各服务 wrapper 调用，不直接使用
# 依赖：scripts/manage-containers.sh, scripts/lib/deploy-check.sh, scripts/lib/image-cleanup.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"

# 加载密钥（Doppler 双模式，per D-03/D-08/D-10）
# envsubst 需要 POSTGRES_USER 等环境变量
load_secrets

source "$PROJECT_ROOT/scripts/manage-containers.sh"
source "$PROJECT_ROOT/scripts/lib/deploy-check.sh"
source "$PROJECT_ROOT/scripts/lib/image-cleanup.sh"

# ============================================
# 参数定义（环境变量，wrapper 可覆盖）
# ============================================
HEALTH_CHECK_MAX_RETRIES="${HEALTH_CHECK_MAX_RETRIES:-30}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-4}"
E2E_MAX_RETRIES="${E2E_MAX_RETRIES:-5}"
E2E_INTERVAL="${E2E_INTERVAL:-2}"
IMAGE_SOURCE="${IMAGE_SOURCE:-build}"
CLEANUP_METHOD="${CLEANUP_METHOD:-none}"
COMPOSE_FILE="${COMPOSE_FILE:-$PROJECT_ROOT/docker/docker-compose.app.yml}"

# ============================================
# 主函数
# ============================================
main()
{
    local apps_dir="${1:-.}"

    # 前置检查
    log_info "=========================================="
    log_info "${SERVICE_NAME} 蓝绿部署开始"
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

    # Compose 迁移检查（仅 keycloak 等服务需要）
    if [ -n "${COMPOSE_MIGRATION_CONTAINER:-}" ]; then
        if [ "$(is_container_running "$COMPOSE_MIGRATION_CONTAINER")" = "true" ]; then
            log_warn "检测到 compose 管理的旧容器: $COMPOSE_MIGRATION_CONTAINER"
            log_info "停止 compose 容器（迁移到蓝绿架构）..."
            docker stop -t 30 "$COMPOSE_MIGRATION_CONTAINER"
            docker rm "$COMPOSE_MIGRATION_CONTAINER"
            log_success "compose 容器已停止并移除"
        fi
    fi

    log_info "活跃环境: $active_env"
    log_info "目标环境: $target_env"
    log_info "目标容器: $target_container"

    # 步骤 1/7: 镜像获取
    log_info "=========================================="
    log_info "步骤 1/7: 获取镜像 (IMAGE_SOURCE=$IMAGE_SOURCE)"
    log_info "=========================================="

    local deploy_image=""
    case "$IMAGE_SOURCE" in
        build)
            local short_sha
            short_sha=$(git -C "$apps_dir" rev-parse --short HEAD 2>/dev/null || true)
            if [ -z "$short_sha" ]; then
                log_error "无法获取 Git SHA（目录: $apps_dir），请确认在 git 仓库中执行"
                exit 1
            fi
            log_info "镜像标签: ${SERVICE_NAME}:${short_sha}"
            docker compose -f "$COMPOSE_FILE" build "$SERVICE_NAME"
            docker tag "${SERVICE_NAME}:latest" "${SERVICE_NAME}:${short_sha}"
            deploy_image="${SERVICE_NAME}:${short_sha}"
            ;;
        pull)
            if [ -z "${SERVICE_IMAGE:-}" ]; then
                log_error "IMAGE_SOURCE=pull 但 SERVICE_IMAGE 未设置"
                exit 1
            fi
            docker pull "$SERVICE_IMAGE"
            deploy_image="$SERVICE_IMAGE"
            log_success "镜像拉取完成: $SERVICE_IMAGE"
            ;;
        none)
            deploy_image="${SERVICE_IMAGE:-${SERVICE_NAME}:latest}"
            log_info "使用已有镜像: $deploy_image"
            ;;
        *)
            log_error "未知 IMAGE_SOURCE: $IMAGE_SOURCE（支持 build/pull/none）"
            exit 1
            ;;
    esac

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

    run_container "$target_env" "$deploy_image"

    # 步骤 3/7: HTTP 健康检查
    log_info "=========================================="
    log_info "步骤 3/7: HTTP 健康检查"
    log_info "=========================================="

    if ! http_health_check "$target_container" "$SERVICE_PORT" "$HEALTH_PATH" "$HEALTH_CHECK_MAX_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
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

    if ! e2e_verify "$target_env" "$SERVICE_PORT" "$HEALTH_PATH" "$E2E_MAX_RETRIES" "$E2E_INTERVAL"; then
        log_error "E2E 验证失败，执行自动回滚"
        update_upstream "$active_env"
        docker exec "$NGINX_CONTAINER" nginx -t
        reload_nginx
        set_active_env "$active_env"
        log_warn "已回滚到 $active_env，新容器 $target_container 仍在运行"
        exit 1
    fi

    # 步骤 6/7: 镜像清理
    log_info "=========================================="
    log_info "步骤 6/7: 镜像清理 (CLEANUP_METHOD=$CLEANUP_METHOD)"
    log_info "=========================================="

    case "$CLEANUP_METHOD" in
        tag-count)
            cleanup_by_tag_count "${CLEANUP_IMAGE_NAME:-$SERVICE_NAME}" "${CLEANUP_KEEP_COUNT:-5}"
            ;;
        dangling)
            cleanup_dangling
            ;;
        none)
            log_info "镜像清理: 跳过（CLEANUP_METHOD=none）"
            ;;
        *)
            log_error "未知 CLEANUP_METHOD: $CLEANUP_METHOD（支持 tag-count/dangling/none）"
            exit 1
            ;;
    esac

    # 步骤 7/7: 完成
    log_success "=========================================="
    log_success "${SERVICE_NAME} 蓝绿部署完成"
    log_success "=========================================="
    log_success "$active_env -> $target_env (镜像: $deploy_image)"
}

main "$@"
