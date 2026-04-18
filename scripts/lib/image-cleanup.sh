#!/bin/bash
# ============================================
# 镜像清理共享库
# ============================================
# 提供 3 个独立的镜像清理函数（per D-01/D-02/D-03）
# 依赖：log.sh
# ============================================

# Source Guard
if [[ -n "${_NODA_IMAGE_CLEANUP_LOADED:-}" ]]; then
  return 0
fi
_NODA_IMAGE_CLEANUP_LOADED=1

# cleanup_by_tag_count - 保留最近 N 个带标签的镜像，删除更早的
# 参数:
#   $1: 镜像名（如 findclass-ssr）
#   $2: 保留数量（默认 5）
# 返回：无（删除旧镜像）
cleanup_by_tag_count() {
  local image_name="$1"
  local keep_count="${2:-5}"

  # 列出所有非 latest 标签的镜像，按创建时间排序（最新在前）
  local images
  images=$(docker images "$image_name" --format '{{.Tag}} {{.CreatedAt}}' \
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
    log_info "  删除 ${image_name}:${tag}"
    docker rmi "${image_name}:${tag}" 2>/dev/null || true
  done

  log_success "旧镜像清理完成"
}

# cleanup_by_date_threshold - 删除超过指定天数的旧镜像和 dangling images
# 参数:
#   $1: 镜像名（如 findclass-ssr 或 keycloak）
#   $2: 保留天数（默认 7）
# 返回：无（删除旧镜像）
cleanup_by_date_threshold() {
  local image_name="$1"
  local retention_days="${2:-7}"

  log_info "镜像清理: 删除超过 ${retention_days} 天的旧镜像..."

  # macOS 兼容：BSD date 使用 -v-${retention_days}d
  local cutoff_epoch
  if date -v-1d >/dev/null 2>&1; then
    cutoff_epoch=$(date -v-"${retention_days}"d +%s)
  else
    cutoff_epoch=$(date -d "${retention_days} days ago" +%s)
  fi

  # 1. 清理带 Git SHA 标签的旧镜像（排除 latest）
  local sha_tags
  sha_tags=$(docker images "$image_name" --format '{{.Tag}}' \
    | grep -v '^latest$' \
    | grep -v '^<none>' || true)

  local deleted=0
  for tag in $sha_tags; do
    # 使用 docker inspect 获取 ISO 8601 创建时间
    local created_iso
    created_iso=$(docker inspect --format '{{.Created}}' "${image_name}:${tag}" 2>/dev/null || echo "")

    if [ -z "$created_iso" ]; then
      continue
    fi

    # 将 ISO 8601 转为 epoch（macOS 兼容）
    local image_epoch
    if date -j -f "%Y-%m-%dT%H:%M:%S" "" >/dev/null 2>&1; then
      # macOS: 截取 ISO 8601 到秒级精度
      local created_short
      created_short=$(echo "$created_iso" | sed 's/\..*//' | sed 's/Z$//')
      image_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$created_short" +%s 2>/dev/null || echo "0")
    else
      image_epoch=$(date -d "$created_iso" +%s 2>/dev/null || echo "0")
    fi

    if [ "$image_epoch" -eq 0 ]; then
      continue
    fi

    if [ "$image_epoch" -lt "$cutoff_epoch" ]; then
      # macOS 兼容的日期显示
      local image_date
      if date -r 0 >/dev/null 2>&1; then
        image_date=$(date -r "$image_epoch" +"%Y-%m-%d")
      else
        image_date=$(date -d "@$image_epoch" +"%Y-%m-%d")
      fi
      log_info "  删除 ${image_name}:${tag} ($image_date)"
      docker rmi "${image_name}:${tag}" 2>/dev/null || true
      deleted=$((deleted + 1))
    fi
  done

  # 2. 清理 dangling images
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
cleanup_dangling() {
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
