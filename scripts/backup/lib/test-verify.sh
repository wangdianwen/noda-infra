#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 验证测试库
# ============================================
# 功能：每周自动验证测试的核心库函数
# 依赖：constants.sh, log.sh, config.sh, cloud.sh, restore.sh, verify.sh
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 加载依赖库
_TEST_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$_TEST_VERIFY_LIB_DIR/constants.sh"
fi

source "$_TEST_VERIFY_LIB_DIR/log.sh"
source "$_TEST_VERIFY_LIB_DIR/config.sh"
source "$_TEST_VERIFY_LIB_DIR/cloud.sh"
source "$_TEST_VERIFY_LIB_DIR/restore.sh"
source "$_TEST_VERIFY_LIB_DIR/verify.sh"

# ============================================
# 测试数据库管理
# ============================================

# create_test_database - 创建测试数据库
# 参数：
#   $1: 原始数据库名
# 返回：测试数据库名
create_test_database() {
  local original_db=$1
  local test_db="${TEST_DB_PREFIX}${original_db}"

  log_info "创建测试数据库: $test_db"

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 检查数据库是否已存在
  if psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d postgres -t -c "SELECT 1 FROM pg_database WHERE datname='$test_db'" 2>/dev/null | grep -q 1; then
    log_warn "测试数据库已存在，将删除重建: $test_db"
    drop_test_database "$test_db"
  fi

  # 创建测试数据库
  if psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d postgres -c "CREATE DATABASE $test_db" >/dev/null 2>&1; then
    log_success "测试数据库创建成功: $test_db"
    echo "$test_db"
  else
    log_error "测试数据库创建失败: $test_db"
    return $EXIT_RESTORE_TEST_FAILED
  fi
}

# drop_test_database - 删除测试数据库
# 参数：
#   $1: 测试数据库名
drop_test_database() {
  local test_db=$1

  # 验证数据库名称
  if [[ ! $test_db =~ ^test_restore_ ]]; then
    log_error "拒绝删除非测试数据库: $test_db"
    return 1
  fi

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  log_info "删除测试数据库: $test_db"

  if psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d postgres -c "DROP DATABASE IF EXISTS $test_db" >/dev/null 2>&1; then
    log_success "测试数据库已删除: $test_db"
  else
    log_warn "测试数据库删除失败（可能不存在）: $test_db"
  fi

  return 0
}

# ============================================
# 下载和恢复功能
# ============================================

# download_latest_backup - 下载最新备份（带重试）
# 参数：
#   $1: 数据库名
# 返回：备份文件路径
download_latest_backup() {
  local db_name=$1
  local max_retries=$TEST_MAX_RETRIES
  local attempt=1

  log_info "下载最新备份: $db_name"

  # 创建临时目录
  mkdir -p "$TEST_BACKUP_DIR"

  # 列出 B2 备份文件并选择最新的
  local backups
  backups=$(list_b2_backups | grep "$db_name" | sort -r | head -1)

  if [[ -z "$backups" ]]; then
    log_error "未找到 $db_name 的备份文件"
    return $EXIT_DOWNLOAD_FAILED
  fi

  # 提取文件名
  local filename
  filename=$(echo "$backups" | awk '{print $2}')

  log_info "找到备份文件: $filename"

  # 下载（带重试）
  while [[ $attempt -le $max_retries ]]; do
    log_info "下载尝试 $attempt/$max_retries"

    local backup_file
    backup_file=$(download_backup "$filename" "$TEST_BACKUP_DIR" 2>/dev/null)

    if [[ -f "$backup_file" ]]; then
      local file_size
      file_size=$(du -h "$backup_file" | cut -f1)
      log_success "下载成功: $backup_file ($file_size)"
      echo "$backup_file"
      return 0
    fi

    ((attempt++))
    if [[ $attempt -le $max_retries ]]; then
      local wait_time=$((2 ** (attempt - 1)))
      log_info "等待 ${wait_time}s 后重试..."
      sleep $wait_time
    fi
  done

  log_error "下载失败（已重试 $max_retries 次）"
  return $EXIT_DOWNLOAD_FAILED
}

# restore_to_test_database - 恢复到测试数据库
# 参数：
#   $1: 备份文件路径
#   $2: 测试数据库名
restore_to_test_database() {
  local backup_file=$1
  local test_db=$2

  log_info "恢复到测试数据库: $test_db"
  log_info "备份文件: $backup_file"

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 验证备份文件
  if ! verify_backup_integrity "$backup_file" >/dev/null 2>&1; then
    log_error "备份文件验证失败"
    return $EXIT_RESTORE_TEST_FAILED
  fi

  # 检查文件类型并恢复
  local file_ext="${backup_file##*.}"

  if [[ "$file_ext" == "dump" ]]; then
    # 使用 pg_restore 恢复 custom format
    if pg_restore -h "$pg_host" -p "$pg_port" -U "$pg_user" \
      -d "$test_db" -j 4 "$backup_file" >/dev/null 2>&1; then
      log_success "数据恢复成功（pg_restore）"
    else
      log_error "数据恢复失败（pg_restore）"
      return $EXIT_RESTORE_TEST_FAILED
    fi
  elif [[ "$file_ext" == "sql" ]]; then
    # 使用 psql 恢复 plain SQL
    if psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
      -d "$test_db" -f "$backup_file" >/dev/null 2>&1; then
      log_success "数据恢复成功（psql）"
    else
      log_error "数据恢复失败（psql）"
      return $EXIT_RESTORE_TEST_FAILED
    fi
  else
    log_error "不支持的备份文件格式: $file_ext"
    return $EXIT_RESTORE_TEST_FAILED
  fi
}

# ============================================
# 多层验证功能
# ============================================

# verify_table_count - 验证表数量
# 参数：
#   $1: 测试数据库名
verify_table_count() {
  local test_db=$1
  local min_tables=1

  log_info "验证表数量..."

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 查询表数量
  local count
  count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d "$test_db" -t -c "
      SELECT COUNT(*)
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE';
    " 2>/dev/null | xargs || echo "0")

  if [[ $count -ge $min_tables ]]; then
    log_success "表数量验证通过: $count 个表"
    return 0
  else
    log_error "表数量验证失败: 仅 $count 个表（至少需要 $min_tables 个）"
    return $EXIT_VERIFY_TEST_FAILED
  fi
}

# verify_data_exists - 验证数据存在性
# 参数：
#   $1: 测试数据库名
verify_data_exists() {
  local test_db=$1

  log_info "验证数据存在性..."

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 获取第一个有数据的表
  local table
  table=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d "$test_db" -t -c "
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = 'public'
      AND table_type = 'BASE TABLE'
      LIMIT 1;
    " 2>/dev/null | xargs || echo "")

  if [[ -z "$table" ]]; then
    log_error "未找到任何表"
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # 检查记录数
  local count
  count=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d "$test_db" -t -c "
      SELECT COUNT(*) FROM $table;
    " 2>/dev/null | xargs || echo "0")

  if [[ $count -gt 0 ]]; then
    log_success "数据验证通过: 表 $table 有 $count 条记录"
    return 0
  else
    log_error "数据验证失败: 表 $table 无数据"
    return $EXIT_VERIFY_TEST_FAILED
  fi
}

# verify_test_restore - 综合验证
# 参数：
#   $1: 测试数据库名
#   $2: 备份文件路径
verify_test_restore() {
  local test_db=$1
  local backup_file=$2

  log_info "开始综合验证..."

  # Layer 1: 文件完整性
  log_info "Layer 1: 文件完整性验证"
  if ! verify_backup_readable "$backup_file" >/dev/null 2>&1; then
    log_error "备份文件可读性验证失败"
    return $EXIT_VERIFY_TEST_FAILED
  fi
  log_success "备份文件可读性验证通过"

  # Layer 2: 数据结构
  log_info "Layer 2: 数据结构验证"
  if ! verify_table_count "$test_db"; then
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # Layer 3: 数据完整性
  log_info "Layer 3: 数据完整性验证"
  if ! verify_data_exists "$test_db"; then
    return $EXIT_VERIFY_TEST_FAILED
  fi

  log_success "综合验证通过"
  return 0
}

# ============================================
# 清理功能
# ============================================

# cleanup_on_timeout - 超时清理
cleanup_on_timeout() {
  log_warn "检测到超时，开始强制清理..."

  # 获取 PostgreSQL 连接参数
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  # 清理临时数据库
  local dbs
  dbs=$(psql -h "$pg_host" -p "$pg_port" -U "$pg_user" \
    -d postgres -t -c "SELECT datname FROM pg_database WHERE datname LIKE '$TEST_DB_PREFIX%'" 2>/dev/null || true)

  for db in $dbs; do
    drop_test_database "$db" 2>/dev/null || true
  done

  # 清理临时文件
  rm -rf "$TEST_BACKUP_DIR" 2>/dev/null || true

  log_warn "超时清理完成"
}
