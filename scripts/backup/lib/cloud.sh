#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 云操作库
# ============================================
# 功能：Backblaze B2 云存储操作
# 依赖：constants.sh, log.sh, config.sh
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 加载依赖库
_CLOUD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$_CLOUD_LIB_DIR/constants.sh"
fi

source "$_CLOUD_LIB_DIR/log.sh"
source "$_CLOUD_LIB_DIR/config.sh"

# ============================================
# rclone 配置管理
# ============================================

# setup_rclone_config - 创建临时 rclone 配置
# 参数：无
# 返回：配置文件路径
setup_rclone_config() {
  local rclone_config
  local b2_account_id
  local b2_application_key

  b2_account_id=$(get_b2_account_id)
  b2_application_key=$(get_b2_application_key)

  # 创建临时配置文件
  rclone_config=$(mktemp)
  chmod 600 "$rclone_config"

  # 直接写入配置文件
  cat > "$rclone_config" <<EOF
[b2remote]
type = b2
account = $b2_account_id
key = $b2_application_key
EOF

  # 验证配置
  if ! rclone listremotes --config "$rclone_config" | grep -q "b2remote:"; then
    log_error "rclone 配置验证失败"
    rm -f "$rclone_config"
    return 1
  fi

  echo "$rclone_config"
}

# cleanup_rclone_config - 清理 rclone 配置文件
# 参数：$1 = 配置文件路径
cleanup_rclone_config() {
  local rclone_config=$1

  if [[ -f "$rclone_config" ]]; then
    rm -f "$rclone_config"
  fi
}

# ============================================
# 云上传功能
# ============================================

# upload_to_b2 - 上传备份文件到 B2
# 参数：
#   $1: 本地备份目录
#   $2: 远程路径（可选，默认为 $B2_BUCKET_NAME/$B2_PATH/YYYY/MM/DD/）
# 返回：0（成功）或非0（失败）
upload_to_b2() {
  local local_dir=$1
  local remote_path=${2:-}
  local max_retries=3
  local attempt=1

  log_info "开始上传到 Backblaze B2..."

  # 验证本地目录
  if [[ ! -d "$local_dir" ]]; then
    log_error "本地备份目录不存在: $local_dir"
    return $EXIT_CLOUD_UPLOAD_FAILED
  fi

  # 设置远程路径
  if [[ -z "$remote_path" ]]; then
    local date_path
    date_path=$(get_date_path)
    local b2_bucket_name
    b2_bucket_name=$(get_b2_bucket_name)
    local b2_path
    b2_path=$(get_b2_path)
    remote_path="${b2_bucket_name}/${b2_path}${date_path}"
  fi

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 重试逻辑
  while [[ $attempt -le $max_retries ]]; do
    log_info "上传尝试 $attempt/$max_retries"

    if rclone copy "$local_dir" "b2remote:$remote_path" \
      --config "$rclone_config" \
      --progress \
      --transfers 4 \
      --checkers 8 \
      --metadata-set "uploaded-at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; then

      # 验证校验和
      if verify_upload_checksum "$local_dir" "b2remote:$remote_path" "$rclone_config"; then
        local file_count
        file_count=$(find "$local_dir" -type f | wc -l | tr -d ' ')
        log_success "上传成功（共 $file_count 个文件）"
        cleanup_rclone_config "$rclone_config"
        return 0
      else
        log_warn "校验和验证失败"
      fi
    fi

    ((attempt++))

    if [[ $attempt -le $max_retries ]]; then
      local wait_time=$((2 ** (attempt - 1)))
      log_info "等待 ${wait_time}s 后重试..."
      sleep $wait_time
    fi
  done

  log_error "上传失败（已重试 $max_retries 次）"
  cleanup_rclone_config "$rclone_config"
  return $EXIT_CLOUD_UPLOAD_FAILED
}

# ============================================
# 校验和验证
# ============================================

# verify_upload_checksum - 验证上传文件的校验和
# 参数：
#   $1: 本地目录
#   $2: 远程路径
#   $3: rclone 配置文件路径
# 返回：0（成功）或非0（失败）
verify_upload_checksum() {
  local local_dir=$1
  local remote_path=$2
  local rclone_config=$3

  log_info "验证校验和..."

  if rclone check "$local_dir" "$remote_path" \
    --config "$rclone_config" \
    --one-way \
    --combined /dev/null \
    --quiet; then
    log_success "校验和验证通过"
    return 0
  else
    log_error "校验和验证失败"
    return 1
  fi
}

# ============================================
# 清理功能
# ============================================

# cleanup_old_backups_b2 - 清理 B2 上的旧备份
# 参数：
#   $1: 保留天数（默认 7 天）
# 返回：0（成功）或非0（失败）
cleanup_old_backups_b2() {
  local retention_days=${1:-7}
  local b2_bucket_name
  local b2_path

  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  log_info "清理 B2 上 ${retention_days} 天前的旧备份..."

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 删除旧文件
  if rclone delete "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    --min-age ${retention_days}d \
    --quiet; then
    log_success "B2 旧备份清理完成"
    cleanup_rclone_config "$rclone_config"
    return 0
  else
    log_error "B2 旧备份清理失败"
    cleanup_rclone_config "$rclone_config"
    return 1
  fi
}

# ============================================
# 辅助函数
# ============================================

# list_b2_backups - 列出 B2 上的所有备份
# 参数：无
# 返回：备份文件列表（每行一个）
list_b2_backups() {
  local b2_bucket_name
  local b2_path

  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 列出文件
  rclone ls "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    2>/dev/null || true

  # 清理配置
  cleanup_rclone_config "$rclone_config"
}
