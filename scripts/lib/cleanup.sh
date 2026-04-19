#!/bin/bash
# ============================================
# 综合清理共享库
# ============================================
# 提供 Docker / Node.js / Jenkins 部署后清理函数
# 依赖：log.sh
# 安全：所有函数均为幂等操作，失败不传播
# ============================================

# Source Guard
if [[ -n "${_NODA_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_CLEANUP_LOADED=1

# ============================================
# 保留策略（可通过环境变量覆盖）
# ============================================
BUILD_CACHE_RETENTION_HOURS="${BUILD_CACHE_RETENTION_HOURS:-24}"
CONTAINER_RETENTION_HOURS="${CONTAINER_RETENTION_HOURS:-24}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"

# -------------------------------------------
# Docker Build Cache 清理 (DOCK-01)
# -------------------------------------------
# 参数:
#   $1: 保留小时数（默认 BUILD_CACHE_RETENTION_HOURS，即 24）
# 返回：无（清理超过保留期的 build cache）
cleanup_docker_build_cache()
{
    local retention_hours="${1:-$BUILD_CACHE_RETENTION_HOURS}"

    log_info "清理 Docker build cache（保留 ${retention_hours} 小时内）..."

    local before_size
    before_size=$(docker buildx du 2>/dev/null | tail -1 | awk '{print $3 $4}' || echo "unknown")
    log_info "Build cache 当前大小: ${before_size}"

    docker buildx prune -f --filter "until=${retention_hours}h" 2>/dev/null || true

    log_success "Docker build cache 清理完成"
}

# -------------------------------------------
# Dangling Images 清理
# -------------------------------------------
# 参数：无
# 返回：无（清理无标签的 dangling images）
cleanup_dangling_images()
{
    log_info "检查 dangling images..."

    local count
    count=$(docker images -f "dangling=true" -q 2>/dev/null | grep -c . || echo "0")

    if [ "$count" -gt 0 ]; then
        docker image prune -f 2>/dev/null || true
        log_success "Dangling images 清理完成: ${count} 个"
    else
        log_info "无需清理 dangling images"
    fi
}

# -------------------------------------------
# 已停止容器清理 (DOCK-02)
# -------------------------------------------
# 参数:
#   $1: 保留小时数（默认 CONTAINER_RETENTION_HOURS，即 24）
# 返回：无（清理超过保留期的已停止容器）
cleanup_stopped_containers()
{
    local retention_hours="${1:-$CONTAINER_RETENTION_HOURS}"

    log_info "清理超过 ${retention_hours} 小时的已停止容器..."

    docker container prune -f --filter "until=${retention_hours}h" 2>/dev/null || true

    log_success "已停止容器清理完成"
}

# -------------------------------------------
# 未使用网络清理
# -------------------------------------------
# 参数：无
# 返回：无（清理未使用的匿名/自定义网络）
# 安全：不删除 external 网络（noda-network 安全）
cleanup_unused_networks()
{
    log_info "清理未使用的 Docker 网络..."

    docker network prune -f 2>/dev/null || true

    log_success "未使用网络清理完成"
}

# -------------------------------------------
# 匿名卷清理 (DOCK-03)
# -------------------------------------------
# 参数：无
# 返回：无（只清理匿名卷，保护命名卷如 postgres_data）
# 安全红线：绝对不加 --all 标志
cleanup_anonymous_volumes()
{
    log_info "清理匿名卷（安全：不删除命名卷，如 postgres_data）..."

    # 注意：不加 --all，只清理匿名卷
    # postgres_data 是命名卷，不会被删除
    docker volume prune -f 2>/dev/null || true

    log_success "匿名卷清理完成"
}

# -------------------------------------------
# node_modules 清理 (CACHE-01)
# -------------------------------------------
# 参数:
#   $1: workspace 路径（必须提供，为空则跳过）
# 返回：无（删除 $workspace/noda-apps/node_modules）
cleanup_node_modules()
{
    local workspace="$1"

    if [ -z "$workspace" ]; then
        return 0
    fi

    local target="$workspace/noda-apps/node_modules"
    if [ -d "$target" ]; then
        local size
        size=$(du -sh "$target" 2>/dev/null | awk '{print $1}' || echo "unknown")
        log_info "清理 node_modules (${size})..."
        rm -rf "$target"
        log_success "node_modules 清理完成"
    else
        log_info "无 node_modules 需要清理"
    fi
}

# -------------------------------------------
# Jenkins 临时文件清理 (FILE-02)
# -------------------------------------------
# 参数:
#   $1: workspace 路径（默认 $WORKSPACE）
# 返回：无（删除 deploy-failure-*.log 和 *.tmp 文件）
cleanup_jenkins_temp_files()
{
    local workspace="${1:-$WORKSPACE}"

    if [ -z "$workspace" ]; then
        return 0
    fi

    log_info "清理临时文件..."

    rm -f "$workspace/deploy-failure-container.log" 2>/dev/null || true
    rm -f "$workspace/deploy-failure-nginx.log" 2>/dev/null || true
    rm -f "$workspace/deploy-failure-infra.log" 2>/dev/null || true
    find "$workspace" -name "*.tmp" -type f -delete 2>/dev/null || true

    log_info "临时文件清理完成"
}

# -------------------------------------------
# infra-pipeline 旧备份清理 (FILE-01)
# -------------------------------------------
# 参数:
#   $1: 服务名（必须提供）
#   $2: 保留天数（默认 BACKUP_RETENTION_DAYS，即 30）
# 返回：无（删除超过保留期的 .sql.gz 备份文件）
cleanup_old_infra_backups()
{
    local service="$1"
    local retention_days="${2:-$BACKUP_RETENTION_DAYS}"
    local backup_dir="${BACKUP_HOST_DIR:-$PROJECT_ROOT/docker/volumes/backup}/infra-pipeline/${service}"

    if [ ! -d "$backup_dir" ]; then
        return 0
    fi

    log_info "清理 ${service} 旧备份（保留 ${retention_days} 天）..."

    local deleted=0
    while read -r _f; do
        deleted=$((deleted + 1))
    done < <(find "$backup_dir" -name "*.sql.gz" -type f -mtime +"${retention_days}" -print -delete 2>/dev/null || true)

    log_success "备份清理完成: ${service}，删除 ${deleted} 个超过 ${retention_days} 天的备份"
}

# -------------------------------------------
# 磁盘快照 (DOCK-04)
# -------------------------------------------
# 参数:
#   $1: 标签（如 "部署前" / "清理后"）
# 返回：无（输出磁盘用量到日志）
disk_snapshot()
{
    local label="${1:-快照}"

    echo ""
    echo "=== 磁盘快照: ${label} ==="
    echo "宿主机: $(df -h / | awk 'NR==2{print $5 " 已用 (" $3 "/" $2 ")"}')"

    # Docker 磁盘概览（静默失败：Docker daemon 可能不可用）
    docker system df 2>/dev/null | head -5 || echo "Docker: 不可用"

    echo ""
}

# -------------------------------------------
# 应用 Pipeline 专用 wrapper
# -------------------------------------------
# cleanup_after_deploy() - 应用部署后全面清理
# 参数:
#   $1: workspace 路径（默认 $WORKSPACE）
# 环境变量跳过控制:
#   SKIP_BUILD_CACHE_CLEANUP     - 跳过 build cache 清理
#   SKIP_CONTAINER_CLEANUP       - 跳过容器清理
#   SKIP_NETWORK_CLEANUP         - 跳过网络清理
#   SKIP_VOLUME_CLEANUP          - 跳过卷清理
#   SKIP_NODE_MODULES_CLEANUP    - 跳过 node_modules 清理
#   SKIP_TEMP_FILES_CLEANUP      - 跳过临时文件清理
cleanup_after_deploy()
{
    local workspace="${1:-$WORKSPACE}"

    log_info "=== 开始部署后清理 ==="

    if [[ -z "${SKIP_BUILD_CACHE_CLEANUP:-}" ]]; then
        cleanup_docker_build_cache "$BUILD_CACHE_RETENTION_HOURS"
    fi

    if [[ -z "${SKIP_CONTAINER_CLEANUP:-}" ]]; then
        cleanup_stopped_containers "$CONTAINER_RETENTION_HOURS"
    fi

    if [[ -z "${SKIP_NETWORK_CLEANUP:-}" ]]; then
        cleanup_unused_networks
    fi

    if [[ -z "${SKIP_VOLUME_CLEANUP:-}" ]]; then
        cleanup_anonymous_volumes
    fi

    if [[ -z "${SKIP_NODE_MODULES_CLEANUP:-}" ]]; then
        cleanup_node_modules "$workspace"
    fi

    if [[ -z "${SKIP_TEMP_FILES_CLEANUP:-}" ]]; then
        cleanup_jenkins_temp_files "$workspace"
    fi

    # 磁盘快照不可跳过
    disk_snapshot "清理后"

    log_success "=== 部署后清理完成 ==="
}

# -------------------------------------------
# 基础设施 Pipeline 专用 wrapper
# -------------------------------------------
# cleanup_after_infra_deploy() - 基础设施部署后清理
# 参数:
#   $1: 服务名（必须提供）
#   $2: workspace 路径（默认 $WORKSPACE）
cleanup_after_infra_deploy()
{
    local service="$1"
    local workspace="${2:-$WORKSPACE}"

    log_info "=== 开始基础设施部署后清理 (${service}) ==="

    # Build cache 清理：仅 noda-ops 使用 docker build
    if [ "$service" = "noda-ops" ]; then
        cleanup_docker_build_cache "$BUILD_CACHE_RETENTION_HOURS"
    fi

    # 旧备份清理
    cleanup_old_infra_backups "$service" "$BACKUP_RETENTION_DAYS"

    # Dangling images 补充清理
    cleanup_dangling_images

    # 已停止容器清理
    cleanup_stopped_containers "$CONTAINER_RETENTION_HOURS"

    # 未使用网络清理
    cleanup_unused_networks

    # 匿名卷清理
    cleanup_anonymous_volumes

    # 临时文件清理
    cleanup_jenkins_temp_files "$workspace"

    # 磁盘快照不可跳过
    disk_snapshot "清理后"

    log_success "=== 基础设施部署后清理完成 (${service}) ==="
}
