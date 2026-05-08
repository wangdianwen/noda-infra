#!/bin/bash
# ============================================
# 手动回退部署脚本（应用服务 — Prod 蓝绿部署）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Promote Pipeline（Build Now -> noda-apps-promote）。
#
# 三分组架构：noda-infra / noda-apps-prod / noda-apps-pre-prod
# 容器命名：noda-apps-prod-{blue|green}
# ============================================

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"

# 加载密钥（Doppler 双模式）
load_secrets

# 回滚目录和文件
ROLLBACK_DIR="/tmp/noda-rollback"
ROLLBACK_FILE="$ROLLBACK_DIR/images-apps-$(date +%s).txt"

# ============================================
# 镜像回滚函数
# ============================================

save_app_image_tags()
{
    mkdir -p "$ROLLBACK_DIR"
    : >"$ROLLBACK_FILE"
    local active_env
    active_env=$(cat /opt/noda/active-env 2>/dev/null || echo "blue")
    local active_container="noda-apps-prod-${active_env}"
    local image_id
    image_id=$(docker inspect --format='{{.Image}}' "$active_container" 2>/dev/null || echo "")
    if [ -n "$image_id" ]; then
        echo "noda-apps=${image_id}" >>"$ROLLBACK_FILE"
        log_info "已保存 ${active_container} 镜像: ${image_id:0:12}..."
    fi

    log_success "应用镜像标签已保存"
}

rollback_app()
{
    if [ ! -f "$ROLLBACK_FILE" ]; then
        log_error "回滚文件不存在: ${ROLLBACK_FILE}"
        return 1
    fi

    local image_id
    image_id=$(grep "noda-apps=" "$ROLLBACK_FILE" | cut -d'=' -f2)
    if [ -z "$image_id" ]; then
        log_error "回滚文件中无 noda-apps 镜像信息"
        return 1
    fi

    local active_env
    active_env=$(cat /opt/noda/active-env 2>/dev/null || echo "blue")
    local active_container="noda-apps-prod-${active_env}"
    log_info "回滚 ${active_container} 到镜像 ${image_id:0:12}..."

    docker stop -t 30 "$active_container" 2>/dev/null || true
    docker rm "$active_container" 2>/dev/null || true

    export NODA_ENVIRONMENT=prod
    source "$PROJECT_ROOT/scripts/manage-containers.sh"
    run_container "$active_env" "$image_id"

    if ! wait_container_healthy "$active_container" 90; then
        log_error "回滚后健康检查失败"
        return 1
    fi

    reload_nginx
    log_success "noda-apps 已回滚"

    return 0
}

# ============================================
# 步骤 1/6: 验证基础设施
# ============================================
log_info "=========================================="
log_info "步骤 1/6: 验证基础设施服务"
log_info "=========================================="

# ============================================
# 步骤 2/6: 保存当前镜像标签
# ============================================
log_info "=========================================="
log_info "步骤 2/6: 保存当前镜像标签"
log_info "=========================================="

save_app_image_tags

# ============================================
# 步骤 3/6: 构建新镜像
# ============================================
log_info "=========================================="
log_info "步骤 3/6: 构建镜像"
log_info "=========================================="

APPS_GIT_SHA=$(cd "$PROJECT_ROOT/../noda-apps" 2>/dev/null && git rev-parse --short HEAD 2>/dev/null || echo "manual")

docker build \
    -t "noda-apps:latest" \
    -t "noda-apps:${APPS_GIT_SHA}" \
    -f "$PROJECT_ROOT/../noda-apps/infra/docker/Dockerfile.noda-apps" \
    --build-arg NEXT_PUBLIC_KEYCLOAK_URL=https://auth.noda.co.nz \
    --build-arg NEXT_PUBLIC_KEYCLOAK_REALM=noda \
    --build-arg NEXT_PUBLIC_KEYCLOAK_CLIENT_ID=noda-frontend \
    --build-arg NEXT_PUBLIC_AUTH_KEYCLOAK_CLIENT_ID=noda-auth \
    "$PROJECT_ROOT/../noda-apps"
log_success "镜像构建完成: noda-apps:${APPS_GIT_SHA}"

# ============================================
# 步骤 4/6: 蓝绿部署
# ============================================
log_info "=========================================="
log_info "步骤 4/6: 蓝绿部署"
log_info "=========================================="

export NODA_ENVIRONMENT=prod
source "$PROJECT_ROOT/scripts/manage-containers.sh"

ACTIVE_ENV=$(get_active_env)
TARGET_ENV=$(get_inactive_env)
TARGET_CONTAINER=$(get_container_name "$TARGET_ENV")

log_info "活跃环境: $ACTIVE_ENV, 目标环境: $TARGET_ENV"
log_info "目标容器: $TARGET_CONTAINER"

# 停止旧目标容器
if [ "$(is_container_running "$TARGET_CONTAINER")" = "true" ]; then
    log_info "停止旧目标容器: $TARGET_CONTAINER"
    docker stop -t 30 "$TARGET_CONTAINER"
    docker rm "$TARGET_CONTAINER"
fi

# 启动新容器到目标环境
run_container "$TARGET_ENV" "noda-apps:${APPS_GIT_SHA}"

# ============================================
# 步骤 5/6: 健康检查 + 流量切换
# ============================================
log_info "=========================================="
log_info "步骤 5/6: 健康检查 + 流量切换"
log_info "=========================================="

if ! wait_container_healthy "$TARGET_CONTAINER" 90; then
    log_info "健康检查失败，清理目标容器..."
    docker rm -f "$TARGET_CONTAINER" 2>/dev/null || true
    exit 1
fi

update_upstream "$TARGET_ENV"
if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    log_error "nginx 配置验证失败，回滚 upstream"
    update_upstream "$ACTIVE_ENV"
    docker rm -f "$TARGET_CONTAINER" 2>/dev/null || true
    exit 1
fi
reload_nginx
set_active_env "$TARGET_ENV"
log_success "流量切换完成: $ACTIVE_ENV -> $TARGET_ENV"

# ============================================
# 步骤 6/6: 清理旧环境容器
# ============================================
log_info "=========================================="
log_info "步骤 6/6: 清理旧环境容器"
log_info "=========================================="

OLD_CONTAINER=$(get_container_name "$ACTIVE_ENV")
if [ "$(is_container_running "$OLD_CONTAINER")" = "true" ]; then
    log_info "停止旧容器: $OLD_CONTAINER"
    docker stop -t 10 "$OLD_CONTAINER"
    docker rm "$OLD_CONTAINER"
fi

# ============================================
# 部署完成
# ============================================
log_success "=========================================="
log_success "应用部署完成！"
log_success "=========================================="
log_info "回滚文件: ${ROLLBACK_FILE}（部署成功，可安全忽略）"
