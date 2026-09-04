#!/bin/bash
# ============================================
# 镜像清理共享库
# ============================================
# 提供 3 个独立的镜像清理函数（per D-01/D-02/D-03）
# 依赖：log.sh
# 支持：NODA_ENVIRONMENT 环境变量（prod/preprod）
# ============================================

# Source Guard
if [[ -n "${_NODA_IMAGE_CLEANUP_LOADED:-}" ]]; then
    return 0
fi
_NODA_IMAGE_CLEANUP_LOADED=1

# 确保 PATH 包含 Docker 可执行文件路径（macOS: /usr/local/bin）
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# 环境参数
NODA_ENVIRONMENT="${NODA_ENVIRONMENT:-prod}"

# 根据环境设置镜像前缀
get_image_prefix()
{
    case "$NODA_ENVIRONMENT" in
        prod)
            echo "noda-apps"
            ;;
        preprod)
            echo "noda-apps-preprod"
            ;;
        *)
            log_error "不支持的环境: $NODA_ENVIRONMENT"
            echo "noda-apps"  # 回退到默认值
            ;;
    esac
}

# cleanup_by_tag_count - 保留最近 N 个带标签的镜像，删除更早的
# 参数:
#   $1: 镜像名（如 noda-apps）
#   $2: 保留数量（默认 5）
# 返回：无（删除旧镜像）
cleanup_by_tag_count()
{
    local image_name="$1"
    local keep_count="${2:-5}"

    # 列出所有非 latest 标签的镜像，按创建时间排序（最新在前）
    local images
    images=$(docker images "$image_name" --format '{{.Tag}} {{.CreatedAt}}' |
        grep -v '^latest ' |
        sort -t' ' -k2 -r |
        awk '{print $1}')

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
        log_info "  删除 ${image_name}:${tag}"
        docker rmi "${image_name}:${tag}" 2>/dev/null || true
    done

    log_success "旧镜像清理完成"
}

# cleanup_by_date_threshold - 删除不被任何容器使用的旧镜像和 dangling images
# 策略：只保留正在被容器使用的镜像 + latest 标签，删除所有其他旧标签镜像
# 参数:
#   $1: 镜像名（如 noda-apps 或 keycloak）
#   $2: 保留天数（已弃用，保留参数兼容性）
# 返回：无（删除未使用的旧镜像）
cleanup_by_date_threshold()
{
    local image_name="$1"
    local retention_days="${2:-7}"

    log_info "镜像清理: 清理 ${image_name} 未使用的旧镜像..."

    # 收集所有容器实际引用的镜像 ID（精确匹配：按容器名过滤）
    local in_use_ids=""
    local container_names
    container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep "^${image_name}" || true)

    for cname in $container_names; do
        local cid
        cid=$(docker inspect --format '{{.Image}}' "$cname" 2>/dev/null || echo "")
        if [ -n "$cid" ]; then
            in_use_ids="${in_use_ids}${cid}"$'\n'
        fi
    done

    # 始终保留 latest 标签对应的镜像 ID
    local latest_id
    latest_id=$(docker inspect --format '{{.Id}}' "${image_name}:latest" 2>/dev/null || echo "")
    if [ -n "$latest_id" ]; then
        in_use_ids="${in_use_ids}${latest_id}"$'\n'
    fi

    in_use_ids=$(echo "$in_use_ids" | sort -u)

    # 列出所有非 latest 标签
    local sha_tags
    sha_tags=$(docker images "$image_name" --format '{{.Tag}}' |
        grep -v '^latest$' |
        grep -v '^<none>' || true)

    local deleted=0
    for tag in $sha_tags; do
        local tag_id
        tag_id=$(docker inspect --format '{{.Id}}' "${image_name}:${tag}" 2>/dev/null || echo "")

        # 检查此镜像是否在用（ID 在 in_use_ids 中）
        if [ -n "$tag_id" ] && echo "$in_use_ids" | grep -qF "$tag_id"; then
            log_info "  保留 ${image_name}:${tag}（正在使用）"
            continue
        fi

        log_info "  删除 ${image_name}:${tag}"
        docker rmi "${image_name}:${tag}" 2>/dev/null || true
        deleted=$((deleted + 1))
    done

    # 清理 dangling images
    local dangling_ids
    dangling_ids=$(docker images -f "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
    for img_id in $dangling_ids; do
        docker rmi "$img_id" 2>/dev/null || true
        deleted=$((deleted + 1))
    done

    if [ "$deleted" -gt 0 ]; then
        log_success "镜像清理完成: 删除 ${deleted} 个镜像"
    else
        log_info "镜像清理: 无需清理"
    fi
}

# cleanup_dangling - 清理无标签的 dangling images
# 参数：无
# 返回：无（删除 dangling 镜像）
cleanup_dangling()
{
    local deleted=0

    local dangling_ids
    dangling_ids=$(docker images -f "dangling=true" --format '{{.ID}}' 2>/dev/null || true)
    for img_id in $dangling_ids; do
        docker rmi "$img_id" 2>/dev/null || true
        deleted=$((deleted + 1))
    done

    if [ "$deleted" -gt 0 ]; then
        log_success "镜像清理完成: 删除 ${deleted} 个 dangling 镜像"
    else
        log_info "镜像清理: 无需清理"
    fi
}

# cleanup_environment - 清理特定环境的镜像
# 参数:
#   $1: 环境（prod 或 preprod）
#   $2: 保留数量（默认 5）
# 返回：无（删除旧镜像）
cleanup_environment()
{
    local env="$1"
    local keep_count="${2:-5}"

    log_info "清理 ${env} 环境镜像..."

    # 临时设置环境变量
    local old_env="${NODA_ENVIRONMENT}"
    export NODA_ENVIRONMENT="$env"

    # 获取镜像前缀
    local image_prefix
    image_prefix=$(get_image_prefix)

    # 执行清理
    cleanup_by_tag_count "$image_prefix" "$keep_count"

    # 恢复环境变量
    export NODA_ENVIRONMENT="$old_env"
}

# cleanup_all_environments - 清理所有环境的镜像
# 参数:
#   $1: 保留数量（默认 5）
# 返回：无（删除所有环境的旧镜像）
cleanup_all_environments()
{
    local keep_count="${1:-5}"

    log_info "清理所有环境镜像..."

    cleanup_environment "prod" "$keep_count"
    cleanup_environment "preprod" "$keep_count"

    log_success "所有环境镜像清理完成"
}
