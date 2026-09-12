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

# ============================================
# Docker 镜像版本保留（2026-09-13）
# ============================================
# 构建机与 r4s 上的 commit-tag 镜像随发布累积（每次构建 +1~2 镜像）。
# 策略：每仓库按创建时间保留最新 KEEP 个镜像 ID（默认 2：当前版 + 回滚锚点），
# 其余删除。在用镜像 docker 自动拒绝删除（|| true 兜底），不阻塞流水线。
# 注意：registry retention（下方）管的是 localhost:5001 里的 tag；本函数管
# docker 宿主机本地镜像，两者互补。
IMAGE_KEEP="${IMAGE_KEEP:-2}"

# docker_image_retention - 保留指定仓库最新 N 个镜像，删除其余
# 参数:
#   $1: 仓库名（如 noda-api）
#   $2: 保留数（默认 IMAGE_KEEP=2）
#   $3: mode（local|remote；remote 经 remote_exec 在 r4s 执行。默认 local）
docker_image_retention()
{
    local repo="$1" keep="${2:-$IMAGE_KEEP}" mode="${3:-local}"
    local imgs ids stale id total
    if [ "$mode" = "remote" ]; then
        imgs=$(remote_exec "docker images $repo --format '{{.CreatedAt}} {{.ID}}'" 2>/dev/null)
    else
        imgs=$(docker images "$repo" --format '{{.CreatedAt}} {{.ID}}' 2>/dev/null)
    fi
    [ -n "$imgs" ] || return 0
    # CreatedAt（ISO 序=字典序）在前整行逆序去重 → 同 ID 多 tag 折叠为 1 版
    ids=$(printf '%s\n' "$imgs" | sort -ur | awk '{print $NF}')
    total=$(printf '%s\n' "$ids" | grep -c . || true)
    [ "$total" -gt "$keep" ] || return 0
    stale=$(printf '%s\n' "$ids" | tail -n +$((keep + 1)))
    log_info "镜像保留($mode): $repo 共 $total 版，保留最新 $keep，删除其余 $((total - keep))"
    if [ "$mode" = "remote" ]; then
        for id in $stale; do remote_exec "docker rmi $id >/dev/null 2>&1 || true"; done
    else
        for id in $stale; do docker rmi "$id" >/dev/null 2>&1 || true; done
    fi
}

# ============================================
# Registry 镜像保留策略（2026-09-13）
# ============================================
# 本地 registry（localhost:5001，经 SSH 反向隧道供 r4s 拉取）磁盘会随发布
# 无限增长——每次 apps 发布 push noda-api/noda-static 两个新 tag。
# 策略：每仓库保留最新 KEEP 个版本（默认 2：当前 + 回滚）；RETIRED 仓库
# （历史遗留、已整体退役）的全部 tag 一律删除。
# 前提：registry 容器需 REGISTRY_STORAGE_DELETE_ENABLED=true（remote-ops.sh
#   transfer_image 创建时注入；存量容器需重建一次）。
# 依赖：curl + python3（macOS 自带）；registry 不可达时静默跳过（不阻塞发布）
REGISTRY_URL="${REGISTRY_URL:-http://localhost:5001}"
REGISTRY_KEEP="${REGISTRY_KEEP:-2}"
REGISTRY_RETIRED_REPOS="${REGISTRY_RETIRED_REPOS:-noda-apps noda-frontend}"

_registry_tags()
{
    curl -sf "$REGISTRY_URL/v2/$1/tags/list" 2>/dev/null |
        python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("tags") or []))' 2>/dev/null
}

# _registry_manifest_headers - manifest 请求的 Accept 头（buildx 推 OCI index，需全兼容）
# 用法: eval "$(_registry_manifest_headers)" 后 curl -H "$MANIFEST_ACCEPT"
_registry_manifest_headers()
{
    printf 'MANIFEST_ACCEPT=application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.oci.image.index.v1+json\n'
}

# _registry_tag_created - 取 tag 对应镜像 config blob 的 created 时间（ISO8601）
# OCI index 需下钻：index → 该仓库平台的 manifest → config blob
# 失败输出空字符串（该 tag 视为最旧，优先淘汰）
_registry_tag_created()
{
    local repo="$1" tag="$2"
    local manifest config_digest
    eval "$(_registry_manifest_headers)"
    manifest=$(curl -sf -H "Accept: $MANIFEST_ACCEPT" \
        "$REGISTRY_URL/v2/$repo/manifests/$tag" 2>/dev/null) || return 0
    config_digest=$(printf '%s' "$manifest" | python3 -c 'import json,sys
m=json.load(sys.stdin)
# 单 manifest → config；OCI index → 取第一个（单平台构建）manifest 的 config
if m.get("config"):
    print(m["config"].get("digest",""))
elif m.get("manifests"):
    print(m["manifests"][0].get("digest",""))
' 2>/dev/null)
    [ -n "$config_digest" ] || return 0
    # 下钻一层（index 场景：config_digest 是子 manifest 的 digest）
    local inner
    inner=$(curl -sf -H "Accept: $MANIFEST_ACCEPT" \
        "$REGISTRY_URL/v2/$repo/manifests/$config_digest" 2>/dev/null) || return 0
    if printf '%s' "$inner" | grep -q '"config"'; then
        manifest="$inner"
        config_digest=$(printf '%s' "$inner" | python3 -c 'import json,sys
m=json.load(sys.stdin)
print(m.get("config",{}).get("digest",""))' 2>/dev/null)
    fi
    [ -n "$config_digest" ] || return 0
    curl -sf "$REGISTRY_URL/v2/$repo/blobs/$config_digest" 2>/dev/null |
        python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("created",""))
except Exception:
    pass' 2>/dev/null
}

_registry_delete_tag()
{
    local repo="$1" tag="$2"
    local digest
    eval "$(_registry_manifest_headers)"
    digest=$(curl -sf -I -H "Accept: $MANIFEST_ACCEPT" \
        "$REGISTRY_URL/v2/$repo/manifests/$tag" 2>/dev/null | awk 'tolower($1)=="docker-content-digest:"{gsub("\r","",$2); print $2}')
    if [ -z "$digest" ]; then
        log_warn "  registry 删除跳过（无 digest）: $repo:$tag"
        return 0
    fi
    local code
    code=$(curl -sf -o /dev/null -w '%{http_code}' -X DELETE "$REGISTRY_URL/v2/$repo/manifests/$digest" 2>/dev/null || echo "000")
    if [ "$code" = "202" ]; then
        log_info "  registry 删除: $repo:$tag"
    else
        log_warn "  registry 删除失败（HTTP $code）: $repo:$tag"
    fi
}

# registry_retention - registry 保留策略主入口（每仓库保留最新 N 版，retired 仓库全删）
# 参数:
#   $1: 保留数量（默认 REGISTRY_KEEP=2）
# 返回: 0（registry 不可达/空仓库时也返回 0，不阻塞发布）
registry_retention()
{
    local keep="${1:-$REGISTRY_KEEP}"

    if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
        log_warn "curl/python3 不可用，跳过 registry 清理"
        return 0
    fi
    if ! curl -sf "$REGISTRY_URL/v2/" >/dev/null 2>&1; then
        log_info "registry（$REGISTRY_URL）不可达，跳过 registry 清理"
        return 0
    fi

    local repos
    repos=$(curl -sf "$REGISTRY_URL/v2/_catalog" 2>/dev/null |
        python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin).get("repositories") or []))' 2>/dev/null)
    if [ -z "$repos" ]; then
        log_info "registry 无仓库，跳过"
        return 0
    fi

    local repo deleted_total=0
    for repo in $repos; do
        local tags
        tags=$(_registry_tags "$repo")
        [ -n "$tags" ] || continue

        # retired 仓库（历史遗留）：全部删除
        case " $REGISTRY_RETIRED_REPOS " in
            *" $repo "*)
                log_info "registry retired 仓库清空: $repo（$(printf '%s\n' $tags | grep -c .) 个 tag）"
                local t
                for t in $tags; do
                    _registry_delete_tag "$repo" "$t"
                    deleted_total=$((deleted_total + 1))
                done
                continue
                ;;
        esac

        # latest tag 不参与版本计数（始终跟随最新发布，删了也会随下次 push 回来）
        local versioned latest_exists
        latest_exists=$(printf '%s\n' $tags | grep -qx latest && echo yes || echo no)
        versioned=$(printf '%s\n' $tags | grep -vx latest | grep -c . || true)
        [ "$versioned" -gt 0 ] || continue

        # 按 config created 时间从新到旧排序，保留前 keep 个，其余删除
        local report tmp
        tmp=$(mktemp)
        for t in $(printf '%s\n' $tags | grep -vx latest); do
            printf '%s %s\n' "$(_registry_tag_created "$repo" "$t")" "$t" >>"$tmp"
        done
        report=$(sort -r "$tmp" | tail -n +$((keep + 1)) | awk '{print $2}')
        rm -f "$tmp"

        if [ -n "$report" ]; then
            log_info "registry 保留策略: $repo 共 $versioned 个版本，保留最新 $keep，删除其余（latest=$latest_exists）"
            local t
            for t in $report; do
                _registry_delete_tag "$repo" "$t"
                deleted_total=$((deleted_total + 1))
            done
        fi
    done

    if [ "$deleted_total" -gt 0 ]; then
        log_success "registry 清理完成: 删除 $deleted_total 个 tag"
    else
        log_info "registry 清理: 无超限 tag"
    fi
    return 0
}
