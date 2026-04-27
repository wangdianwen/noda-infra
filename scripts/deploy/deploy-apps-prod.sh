#!/bin/bash
# ============================================
# 手动回退部署脚本（应用服务）
# ============================================
# NOTE: 此脚本作为 Jenkins Pipeline 不可用时的紧急回退方案保留。
# 正常部署请使用 Jenkins Pipeline（Build Now -> findclass-deploy）。
#
# 原有功能：部署 findclass-ssr 应用服务（重新构建镜像 + 部署）
# 使用独立的 docker-compose.app.yml（name: noda-apps）
# findclass-ssr 同时服务 class.noda.co.nz 和 noda.co.nz 域名
# ============================================

set -euo pipefail

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/health.sh"
source "$PROJECT_ROOT/scripts/lib/secrets.sh"

# 加载密钥（Doppler 双模式，per D-08/D-09/D-10）
load_secrets

# 应用服务使用独立的 compose 文件（noda-apps 项目）
COMPOSE_FILE="-f docker/docker-compose.app.yml"

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
    local image_id
    image_id=$(docker inspect --format='{{.Image}}' findclass-ssr 2>/dev/null || echo "")
    if [ -n "$image_id" ]; then
        echo "findclass-ssr=${image_id}" >>"$ROLLBACK_FILE"
        log_info "已保存 findclass-ssr 镜像: ${image_id:0:12}..."
    fi

    log_success "应用镜像标签已保存"
}

# 使用 compose override 回滚到保存的镜像版本
rollback_app()
{
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

    # 生成 compose override 文件指定回滚镜像
    local rollback_compose="$ROLLBACK_DIR/docker-compose.app-rollback.yml"
    cat >"$rollback_compose" <<EOF
services:
  findclass-ssr:
    image: ${image_id}
EOF

    if ! docker compose $COMPOSE_FILE -f "$rollback_compose" up -d --no-deps --force-recreate findclass-ssr; then
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

# 基础设施验证由 Jenkins Pipeline 健康检查阶段覆盖
# 旧 verify-infrastructure.sh 已删除（硬编码旧架构路径，不可用）

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
log_info "步骤 3/5: 构建镜像"
log_info "=========================================="

docker compose $COMPOSE_FILE build findclass-ssr
log_success "镜像构建完成"

# ============================================
# 步骤 4/5: 部署新版本
# ============================================
log_info "=========================================="
log_info "步骤 4/5: 部署新版本"
log_info "=========================================="

docker compose $COMPOSE_FILE up -d --force-recreate findclass-ssr

# ============================================
# 步骤 5/5: 等待健康检查
# ============================================
log_info "=========================================="
log_info "步骤 5/5: 等待健康检查"
log_info "=========================================="

if ! wait_container_healthy findclass-ssr 90; then
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
