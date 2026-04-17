#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 数据库操作库
# ============================================
# 功能：数据库发现、备份、全局对象备份
# 依赖：constants.sh, log.sh, util.sh
# ============================================

set -euo pipefail

# 加载依赖库
_DB_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 条件 source constants.sh（避免重复定义 readonly 变量）
if [[ -z "${EXIT_SUCCESS+x}" ]]; then
  source "$_DB_LIB_DIR/constants.sh"
fi

source "$_DB_LIB_DIR/log.sh"
source "$_DB_LIB_DIR/util.sh"

# 条件 source alert.sh（用于数据量异常告警）
if [[ "$(type -t send_alert)" != "function" ]]; then
  source "$_DB_LIB_DIR/alert.sh"
fi

# ============================================
# 全局变量
# ============================================
# 记录已创建的备份文件列表（用于失败时清理）
CREATED_BACKUPS=()

# ============================================
# 数据库发现函数
# ============================================

# 发现所有用户数据库（排除模板数据库）
# 返回：数据库名称列表（每行一个）
discover_databases() {
  PGPASSWORD=$POSTGRES_PASSWORD psql -h noda-infra-postgres-prod -U postgres -d postgres -t -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
}

# ============================================
# 数据库备份函数
# ============================================

# 备份单个数据库
# 参数：
#   $1: 数据库名
#   $2: 备份目录
#   $3: 时间戳
# 返回：备份文件路径（成功）或非0退出码（失败）
backup_database() {
  local db_name=$1
  local backup_dir=$2
  local timestamp=$3

  local backup_file="${backup_dir}/${db_name}_${timestamp}.dump"

  log_info "开始备份数据库: $db_name"

  # 使用 pg_dump -Fc 格式备份（D-03）
  if PGPASSWORD=$POSTGRES_PASSWORD pg_dump -h noda-infra-postgres-prod -U postgres -Fc -f "$backup_file" "$db_name"; then
    # 设置文件权限为 600（D-13）
    chmod 600 "$backup_file"

    # 记录已创建的备份文件（用于失败时清理）
    CREATED_BACKUPS+=("$backup_file")

    log_success "数据库备份成功: $db_name"
    echo "$backup_file"
    return $EXIT_SUCCESS
  else
    log_error "数据库备份失败: $db_name"
    return $EXIT_BACKUP_FAILED
  fi
}

# ============================================
# 全局对象备份函数
# ============================================

# 备份全局对象（角色和表空间）
# 参数：
#   $1: 备份目录
#   $2: 时间戳
# 返回：备份文件路径（成功）或非0退出码（失败）
backup_globals() {
  local backup_dir=$1
  local timestamp=$2

  local backup_file="${backup_dir}/globals_${timestamp}.sql"

  log_info "开始备份全局对象（角色和表空间）"

  # 使用 pg_dumpall -g 备份全局对象（D-32）
  if PGPASSWORD=$POSTGRES_PASSWORD pg_dumpall -h noda-infra-postgres-prod -U postgres -g -U postgres -f "$backup_file"; then
    # 设置文件权限为 600（D-13）
    chmod 600 "$backup_file"

    # 记录已创建的备份文件（用于失败时清理）
    CREATED_BACKUPS+=("$backup_file")

    log_success "全局对象备份成功"
    echo "$backup_file"
    return $EXIT_SUCCESS
  else
    log_error "全局对象备份失败"
    return $EXIT_BACKUP_FAILED
  fi
}

# ============================================
# 批量备份函数
# ============================================

# 备份所有数据库和全局对象
# 参数：
#   $1: 备份目录
#   $2: 时间戳
# 返回：0（成功）或非0（失败）
backup_all_databases() {
  local backup_dir=$1
  local timestamp=$2

  log_info "开始备份所有数据库和全局对象"

  # 发现所有用户数据库
  local databases
  databases=$(discover_databases)

  # 转换为数组（去除空行和空格）
  local db_array=()
  while IFS= read -r line; do
    local db_name
    db_name=$(echo "$line" | xargs) # 去除前后空格
    if [ -n "$db_name" ]; then
      db_array+=("$db_name")
    fi
  done <<< "$databases"

  local total_databases=${#db_array[@]}
  log_info "发现 $total_databases 个用户数据库"

  # 清空已创建的备份文件列表
  CREATED_BACKUPS=()

  # 首先备份全局对象（D-02）
  local current=0
  local total=$((total_databases + 1)) # 数据库数量 + 全局对象

  current=$((current + 1))
  log_progress "$current" "$total" "备份全局对象"

  local globals_file
  if ! globals_file=$(backup_globals "$backup_dir" "$timestamp"); then
    log_error "全局对象备份失败，清理已创建的备份文件"
    cleanup_created_backups
    return $EXIT_BACKUP_FAILED
  fi

  # 串行备份每个数据库（D-04）
  local db_name
  for db_name in "${db_array[@]}"; do
    current=$((current + 1))

    # 数据量校验（Phase 6）
    log_progress "$current" "$total" "校验数据量: $db_name"
    if ! check_data_volume_before_backup "$db_name"; then
      log_error "数据库 $db_name 数据量校验失败"

      # 根据严格模式决定是否继续
      if [[ "$DATA_VOLUME_STRICT_MODE" == "true" ]]; then
        log_error "严格模式：终止备份"
        cleanup_created_backups
        return $EXIT_BACKUP_FAILED
      else
        log_warn "非严格模式：继续备份"
      fi
    fi

    log_progress "$current" "$total" "备份数据库: $db_name"

    local backup_file
    if ! backup_file=$(backup_database "$db_name" "$backup_dir" "$timestamp"); then
      log_error "数据库 $db_name 备份失败，清理已创建的备份文件"
      cleanup_created_backups
      return $EXIT_BACKUP_FAILED
    fi
  done

  log_success "所有数据库备份完成（共 $total_databases 个数据库 + 全局对象）"
  return $EXIT_SUCCESS
}

# ============================================
# 数据量校验函数（Phase 6）
# ============================================

# 获取数据库统计信息
# 参数：
#   $1: 数据库名
# 返回：JSON 格式的统计信息（表数量、总行数、数据库大小）
get_database_stats() {
  local db_name=$1

  # 查询数据库统计信息
  local stats=$(PGPASSWORD=$POSTGRES_PASSWORD psql -h noda-infra-postgres-prod -U postgres -d "$db_name" -t -c "
    SELECT
      (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') as table_count,
      (SELECT COALESCE(SUM(n_live_tup), 0)::bigint FROM pg_stat_user_tables) as total_rows,
      pg_database_size('$db_name') as db_size
 ;" 2>/dev/null)

  # 解析结果（psql -t 用 | 分隔列）
  local table_count=$(echo "$stats" | awk -F'|' '{print $1}' | xargs)
  local total_rows=$(echo "$stats" | awk -F'|' '{print $2}' | xargs)
  local db_size=$(echo "$stats" | awk -F'|' '{print $3}' | xargs)

  # 处理可能的 NULL 值
  table_count=${table_count:-0}
  total_rows=${total_rows:-0}
  db_size=${db_size:-0}

  # 返回 JSON
  cat <<EOF
{
  "database": "$db_name",
  "table_count": $table_count,
  "total_rows": $total_rows,
  "db_size": $db_size,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
}

# 获取历史备份文件大小
# 参数：
#   $1: 数据库名
#   $2: 历史天数（默认 7 天）
# 返回：平均备份大小（字节）
get_historical_backup_size() {
  local db_name=$1
  local history_days=${2:-$DATA_VOLUME_HISTORY_DAYS}

  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "0"
    return
  fi

  # 计算截止时间
  local cutoff_time
  cutoff_time=$(date -d "$history_days days ago" +%s 2>/dev/null || date -v-${history_days}d +%s)

  # 获取该数据库的历史备份记录
  local historical_sizes=$(jq \
    "[.[] | select(.database==\"$db_name\" and .operation==\"backup\" and .timestamp >= \"$cutoff_time\") | .file_size] | \
     map(select(. != 0 and . != null)) | \
     if length > 0 then add / length else 0 end" \
    "$HISTORY_FILE" 2>/dev/null)

  # 转为整数（jq 平均值可能返回浮点数，bash 不支持浮点比较）
  echo "${historical_sizes:-0}" | cut -d. -f1
}

# 判断数据量是否异常
# 参数：
#   $1: 数据库名
#   $2: 当前数据库大小
#   $3: 历史平均大小
# 返回：0（正常）或 1（异常）
is_data_volume_anomaly() {
  local db_name=$1
  local current_size=$2
  local historical_avg=$3

  # 如果没有历史数据，不算异常
  if [[ $historical_avg -eq 0 ]]; then
    return 1  # 返回 1 表示无法判断（不是异常）
  fi

  # 计算变化百分比
  local change_percent=$(( (current_size - historical_avg) * 100 / historical_avg ))
  local abs_change_percent=${change_percent#-}  # 取绝对值

  # 判断是否超过阈值
  if [[ $abs_change_percent -gt $DATA_VOLUME_ANOMALY_THRESHOLD ]]; then
    return 0  # 返回 0 表示异常
  else
    return 1  # 返回 1 表示正常
  fi
}

# 备份前数据量校验
# 参数：
#   $1: 数据库名
# 返回：0（校验通过）或 非0（校验失败）
check_data_volume_before_backup() {
  local db_name=$1

  # 检查是否启用数据量校验
  if [[ "$DATA_VOLUME_CHECK_ENABLED" != "true" ]]; then
    return 0
  fi

  log_info "校验数据库数据量: $db_name"

  # 获取当前数据库统计信息
  local current_stats
  current_stats=$(get_database_stats "$db_name")

  local current_size
  current_size=$(echo "$current_stats" | jq -r '.db_size')

  local table_count
  table_count=$(echo "$current_stats" | jq -r '.table_count')

  local total_rows
  total_rows=$(echo "$current_stats" | jq -r '.total_rows')

  log_info "  表数量: $table_count"
  log_info "  总行数: $total_rows"
  log_info "  数据库大小: $(numfmt --to=iec $current_size 2>/dev/null || echo $current_size) bytes"

  # 获取历史备份大小
  local historical_size
  historical_size=$(get_historical_backup_size "$db_name" "$DATA_VOLUME_HISTORY_DAYS")

  if [[ $historical_size -gt 0 ]]; then
    log_info "  历史平均大小: $(numfmt --to=iec $historical_size 2>/dev/null || echo $historical_size) bytes"

    # 判断是否异常
    if is_data_volume_anomaly "$db_name" "$current_size" "$historical_size"; then
      local change_percent=$(( (current_size - historical_size) * 100 / historical_size ))

      log_error "=========================================="
      log_error "数据量异常检测: $db_name"
      log_error "=========================================="
      log_error "当前大小: $(numfmt --to=iec $current_size 2>/dev/null || echo $current_size) bytes"
      log_error "历史平均: $(numfmt --to=iec $historical_size 2>/dev/null || echo $historical_size) bytes"
      log_error "变化: ${change_percent}%"
      log_error "阈值: ±${DATA_VOLUME_ANOMALY_THRESHOLD}%"
      log_error "=========================================="

      # 发送告警
      send_alert "data_volume_anomaly" "$db_name" \
        "数据量异常: $db_name - 当前 $(numfmt --to=iec $current_size 2>/dev/null || echo $current_size)B，历史平均 $(numfmt --to=iec $historical_size 2>/dev/null || echo $historical_size)B，变化 ${change_percent}%"

      # 根据严格模式决定是否终止
      if [[ "$DATA_VOLUME_STRICT_MODE" == "true" ]]; then
        log_error "严格模式：终止备份"
        return $EXIT_BACKUP_FAILED
      else
        log_warn "非严格模式：继续备份，但已发送告警"
      fi
    else
      log_success "数据量校验通过: $db_name"
    fi
  else
    log_info "无历史数据，跳过数据量对比"
  fi

  return 0
}

# ============================================
# 清理函数
# ============================================

# 清理已创建的备份文件（失败时调用）
cleanup_created_backups() {
  if [ ${#CREATED_BACKUPS[@]} -eq 0 ]; then
    return
  fi

  log_warn "清理已创建的备份文件（共 ${#CREATED_BACKUPS[@]} 个）"

  local file
  for file in "${CREATED_BACKUPS[@]}"; do
    if [ -f "$file" ]; then
      rm -f "$file"
      log_warn "已删除: $file"
    fi
  done

  # 清空列表
  CREATED_BACKUPS=()
}
