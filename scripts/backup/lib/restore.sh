#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 恢复库
# ============================================
# 功能：从 B2 云存储恢复数据库
# 依赖：log.sh, config.sh, cloud.sh
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 加载依赖库
_RESTORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_RESTORE_LIB_DIR/log.sh"
source "$_RESTORE_LIB_DIR/config.sh"
source "$_RESTORE_LIB_DIR/cloud.sh"

# ============================================
# 列出备份功能
# ============================================

# list_backups_b2 - 列出 B2 上所有可用的备份文件
# 参数：无
# 返回：按时间排序的备份列表（格式：日期 数据库 文件名）
list_backups_b2() {
  log_info "获取 B2 备份列表..."

  local b2_bucket_name
  local b2_path

  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 列出文件并解析
  local backups
  backups=$(rclone ls "b2remote:${b2_bucket_name}/${b2_path}" \
    --config "$rclone_config" \
    2>/dev/null || true)

  # 清理配置
  cleanup_rclone_config "$rclone_config"

  if [[ -z "$backups" ]]; then
    log_warn "未找到任何备份文件"
    return 0
  fi

  # 解析并格式化输出
  echo ""
  echo "可用的备份文件："
  echo "─────────────────────────────────────────────────"

  echo "$backups" | while read -r size filename; do
    # 从文件名提取信息
    # 格式: dbname_YYYYMMDD_HHMMSS.sql 或 .dump
    if [[ $filename =~ ^([^_]+)_([0-9]{8})_([0-9]{6})\.(sql|dump)$ ]]; then
      local dbname="${BASH_REMATCH[1]}"
      local date="${BASH_REMATCH[2]}"
      local time="${BASH_REMATCH[3]}"
      local ext="${BASH_REMATCH[4]}"

      # 格式化日期时间
      local formatted_date="${date:0:4}-${date:4:2}-${date:6:2}"
      local formatted_time="${time:0:2}:${time:2:2}:${time:4:2}"

      # 格式化文件大小
      local size_mb
      size_mb=$(echo "scale=2; $size / 1048576" | bc)

      printf "%-20s %-15s %10s MB  %s\n" \
        "$formatted_date $formatted_time" \
        "$dbname" \
        "$size_mb" \
        "$filename"
    fi
  done

  echo "─────────────────────────────────────────────────"
}

# ============================================
# 下载备份功能
# ============================================

# download_backup - 从 B2 下载备份文件
# 参数：
#   $1: 备份文件名
#   $2: 本地保存目录（可选，默认为临时目录）
# 返回：0（成功）或非0（失败）
download_backup() {
  local backup_filename=$1
  local local_dir=${2:-$(mktemp -d)}

  # 注意：此函数通过 stdout 返回文件路径，所有日志输出重定向到 stderr
  log_info "下载备份文件: $backup_filename" >&2

  # 验证文件名
  if [[ ! $backup_filename =~ ^[^_]+_[0-9]{8}_[0-9]{6}\.(sql|dump)$ ]]; then
    log_error "无效的备份文件名格式: $backup_filename"
    return 1
  fi

  # 获取 B2 配置
  local b2_bucket_name
  local b2_path
  b2_bucket_name=$(get_b2_bucket_name)
  b2_path=$(get_b2_path)

  # 创建 rclone 配置
  local rclone_config
  rclone_config=$(setup_rclone_config)

  # 下载文件
  log_info "从 B2 下载中..." >&2
  if rclone copy "b2remote:${b2_bucket_name}/${b2_path}" \
    "$local_dir" \
    --config "$rclone_config" \
    --include "$backup_filename" \
    --progress >&2; then

    cleanup_rclone_config "$rclone_config"

    # 验证文件已下载（rclone copy 保留目录结构，文件可能在子目录中）
    local downloaded_file=""
    if [[ -f "$local_dir/$backup_filename" ]]; then
      downloaded_file="$local_dir/$backup_filename"
    else
      # 递归查找下载的文件
      downloaded_file=$(find "$local_dir" -name "$backup_filename" -type f 2>/dev/null | head -1 || true)
    fi

    if [[ -n "$downloaded_file" && -f "$downloaded_file" ]]; then
      local file_size=""
      file_size=$(du -h "$downloaded_file" 2>/dev/null | cut -f1 || true)
      log_success "下载成功（文件大小: ${file_size:-unknown}）" >&2
      echo "$downloaded_file"
      return 0
    else
      log_error "文件下载失败"
      return 1
    fi
  else
    cleanup_rclone_config "$rclone_config"
    log_error "下载失败"
    return 1
  fi
}

# ============================================
# 恢复数据库功能
# ============================================

# restore_database - 恢复数据库
# 参数：
#   $1: 备份文件路径
#   $2: 目标数据库名（可选，默认从文件名提取）
#   $3: PostgreSQL 连接参数（可选）
# 返回：0（成功）或非0（失败）
restore_database() {
  local backup_file=$1
  local target_db=${2:-}
  local pg_params=${3:-}

  log_info "开始恢复数据库..."

  # 环境检测：宿主机 vs 容器
  local is_host=false
  if [[ ! -f /.dockerenv ]]; then
    is_host=true
  fi

  # 验证备份文件存在
  if [[ ! -f "$backup_file" ]]; then
    log_error "备份文件不存在: $backup_file"
    return 1
  fi

  # 提取数据库名（如果未指定）
  if [[ -z "$target_db" ]]; then
    if [[ $backup_file =~ ^([^/]+)_[0-9]{8}_[0-9]{6}\.(sql|dump)$ ]]; then
      target_db="${BASH_REMATCH[1]}"
      log_info "从文件名提取目标数据库: $target_db"
    else
      log_error "无法从文件名提取数据库名，请手动指定"
      return 1
    fi
  fi

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 构建连接参数
  if [[ -z "$pg_params" ]]; then
    pg_params="-h $pg_host -p $pg_port -U $pg_user"
  fi

  # 检查文件类型并选择恢复方法
  local file_ext
  file_ext="${backup_file##*.}"

  log_info "目标数据库: $target_db"
  log_info "备份文件: $backup_file"

  # 确认操作
  echo ""
  echo "⚠️  警告：恢复操作将覆盖目标数据库的所有数据"
  echo "目标数据库: $target_db"
  echo "备份文件: $backup_file"
  echo ""
  read -p "确认继续？(yes/no): " confirm

  if [[ "$confirm" != "yes" ]]; then
    log_info "恢复操作已取消"
    return 0
  fi

  # 删除旧数据库（如果存在）
  log_info "删除旧数据库（如果存在）..."
  if [[ "$is_host" == true ]]; then
    docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $target_db" 2>/dev/null && log_info "已删除旧数据库" || true
  else
    psql $pg_params -d postgres -c "DROP DATABASE IF EXISTS $target_db" 2>/dev/null && log_info "已删除旧数据库" || true
  fi

  # 创建新数据库
  log_info "创建新数据库..."
  if [[ "$is_host" == true ]]; then
    if ! docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c "CREATE DATABASE $target_db" 2>/dev/null; then
      log_error "创建数据库失败"
      return 1
    fi
  else
    if ! psql $pg_params -d postgres -c "CREATE DATABASE $target_db" 2>/dev/null; then
      log_error "创建数据库失败"
      return 1
    fi
  fi
  log_success "数据库创建成功"

  # 恢复数据
  log_info "开始恢复数据..."
  if [[ "$file_ext" == "dump" ]]; then
    # 使用 pg_restore 恢复 custom format
    if [[ "$is_host" == true ]]; then
      # 宿主机: 需要将文件复制到容器内，因为 pg_restore 在容器内运行
      local container_backup_path="/tmp/restore_$(date +%s)_$(basename "$backup_file")"
      docker cp "$backup_file" "noda-infra-postgres-prod:$container_backup_path" 2>/dev/null
      if docker exec noda-infra-postgres-prod pg_restore -U postgres -d "$target_db" -j 4 "$container_backup_path"; then
        docker exec noda-infra-postgres-prod rm -f "$container_backup_path" 2>/dev/null || true
        log_success "数据恢复成功"
      else
        docker exec noda-infra-postgres-prod rm -f "$container_backup_path" 2>/dev/null || true
        log_error "数据恢复失败"
        return 1
      fi
    else
      if pg_restore $pg_params -d "$target_db" -j 4 "$backup_file"; then
        log_success "数据恢复成功"
      else
        log_error "数据恢复失败"
        return 1
      fi
    fi
  else
    # 使用 psql 恢复 plain SQL
    if [[ "$is_host" == true ]]; then
      if docker exec -i noda-infra-postgres-prod psql -U postgres -d "$target_db" < "$backup_file"; then
        log_success "数据恢复成功"
      else
        log_error "数据恢复失败"
        return 1
      fi
    else
      if psql $pg_params -d "$target_db" -f "$backup_file"; then
        log_success "数据恢复成功"
      else
        log_error "数据恢复失败"
        return 1
      fi
    fi
  fi

  # 验证恢复结果
  log_info "验证恢复结果..."
  local table_count
  if [[ "$is_host" == true ]]; then
    table_count=$(docker exec noda-infra-postgres-prod psql -U postgres -d "$target_db" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null | xargs || echo "0")
  else
    table_count=$(psql $pg_params -d "$target_db" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null | xargs || echo "0")
  fi

  if [[ "$table_count" -gt 0 ]]; then
    log_success "恢复完成（共 $table_count 个表）"
    return 0
  else
    log_warn "恢复完成，但未找到任何表"
    return 0
  fi
}

# ============================================
# 验证备份功能
# ============================================

# verify_backup_integrity - 验证备份文件完整性
# 参数：
#   $1: 备份文件路径
# 返回：0（成功）或非0（失败）
verify_backup_integrity() {
  local backup_file=$1

  log_info "验证备份文件完整性..."

  # 环境检测：宿主机 vs 容器
  local is_host=false
  if [[ ! -f /.dockerenv ]]; then
    is_host=true
  fi

  # 检查文件存在
  if [[ ! -f "$backup_file" ]]; then
    log_error "备份文件不存在: $backup_file"
    return 1
  fi

  # 检查文件大小
  local file_size
  file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)

  if [[ "$file_size" -lt 100 ]]; then
    log_error "备份文件过小，可能已损坏: $file_size bytes"
    return 1
  fi

  # 检查文件类型
  local file_ext
  file_ext="${backup_file##*.}"

  if [[ "$file_ext" == "dump" ]]; then
    # 验证 pg_dump custom format
    local pg_restore_result=0
    if [[ "$is_host" == true ]]; then
      # 宿主机: 需要将文件复制到容器内，因为 pg_restore 在容器内运行
      local container_verify_path="/tmp/verify_$(date +%s)_$(basename "$backup_file")"
      docker cp "$backup_file" "noda-infra-postgres-prod:$container_verify_path" 2>/dev/null
      docker exec noda-infra-postgres-prod pg_restore -l "$container_verify_path" >/dev/null 2>&1 || pg_restore_result=$?
      docker exec noda-infra-postgres-prod rm -f "$container_verify_path" 2>/dev/null || true
    else
      pg_restore -l "$backup_file" >/dev/null 2>&1 || pg_restore_result=$?
    fi
    if [[ $pg_restore_result -ne 0 ]]; then
      log_error "备份文件格式无效"
      return 1
    fi
  elif [[ "$file_ext" == "sql" ]]; then
    # 验证 SQL 文件
    if ! grep -q "PostgreSQL database dump" "$backup_file" 2>/dev/null; then
      log_error "备份文件不是有效的 PostgreSQL dump"
      return 1
    fi
  fi

  log_success "备份文件验证通过"
  return 0
}
