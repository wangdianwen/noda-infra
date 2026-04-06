#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 主脚本
# ============================================
# 功能：完整的备份流程（健康检查 → 备份 → 验证 → 云上传 → 清理）
# 用法：./backup-postgres.sh [选项]
# 选项：
#   --list-databases    列出所有可备份的数据库
#   --dry-run          模拟备份执行（不实际备份）
#   --test             测试模式（创建测试数据库并验证，D-43）
#   --help             显示帮助信息
# ============================================

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载常量定义（必须最先加载，因为包含 readonly 变量）
source "$SCRIPT_DIR/lib/constants.sh"

# 加载库文件
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/health.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/util.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/cloud.sh"
source "$SCRIPT_DIR/lib/alert.sh"
source "$SCRIPT_DIR/lib/metrics.sh"

# 全局变量
PID_FILE="/tmp/backup-postgres.pid"
LOCK_TIMEOUT=3600  # 1小时
DRY_RUN=false
TEST_MODE=false

# ============================================
# 函数：show_help
# 功能：显示帮助信息
# ============================================
show_help() {
  cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --list-databases    列出所有可备份的数据库
  --dry-run          模拟备份执行（不实际备份）
  --test             测试模式（创建测试数据库并验证完整流程）
  --help             显示帮助信息

示例:
  $(basename "$0")                 # 备份所有数据库
  $(basename "$0") --list-databases  # 列出数据库
  $(basename "$0") --dry-run       # 模拟备份
  $(basename "$0") --test          # 测试模式（D-43）
EOF
}

# ============================================
# 函数：list_databases
# 功能：列出所有可备份的数据库
# ============================================
list_databases() {
  log_info "可备份的数据库列表："
  local databases=$(discover_databases)
  local count=0
  for db in $databases; do
    echo "  • $db"
    ((count++))
  done
  log_info "总计: $count 个数据库"
}

# ============================================
# 函数：acquire_lock
# 功能：获取锁，防止并发执行
# ============================================
acquire_lock() {
  if [ -f "$PID_FILE" ]; then
    local pid=$(cat "$PID_FILE")
    local pid_age=$(($(date +%s) - $(stat -f%m "$PID_FILE" 2>/dev/null || stat -c%Y "$PID_FILE" 2>/dev/null)))
    if [ $pid_age -gt $LOCK_TIMEOUT ]; then
      log_warn "检测到过期的锁文件（PID: $pid，已锁定 ${pid_age} 秒），自动清理"
      release_lock
    else
      log_error "另一个备份实例正在运行（PID: $pid）"
      exit 1
    fi
  fi
  echo $$ > "$PID_FILE"
  log_info "获取锁成功（PID: $$）"
}

# ============================================
# 函数：release_lock
# 功能：释放锁
# ============================================
release_lock() {
  if [ -f "$PID_FILE" ]; then
    rm -f "$PID_FILE"
    log_info "释放锁成功"
  fi
}

# ============================================
# 函数：cleanup_old_backups
# 功能：清理旧备份文件
# 参数：
#   $1 - backup_dir: 备份目录路径
# ============================================
cleanup_old_backups() {
  local backup_dir=$1
  local retention_days=$(get_retention_days)
  log_info "清理 $retention_days 天前的旧备份..."

  # 查找并删除旧备份
  find "$backup_dir" -type f -name "*.dump" -mtime +$retention_days -delete 2>/dev/null || true
  find "$backup_dir" -type f -name "globals_*.sql" -mtime +$retention_days -delete 2>/dev/null || true
  find "$backup_dir" -type f -name "metadata_*.json" -mtime +$retention_days -delete 2>/dev/null || true

  log_success "旧备份清理完成"
}

# ============================================
# 函数：run_test_mode
# 功能：测试模式（D-43 完整实现）
# 说明：调用 test_restore.sh 脚本验证完整备份和恢复流程
# ============================================
run_test_mode() {
  log_info "=========================================="
  log_info "测试模式：完整备份和恢复流程验证"
  log_info "=========================================="

  local test_script="$SCRIPT_DIR/tests/test_restore.sh"

  # 检查测试脚本是否存在
  if [ ! -f "$test_script" ]; then
    log_error "测试脚本不存在: $test_script"
    log_error "请确保已运行 Wave 0 计划创建测试基础设施"
    return 1
  fi

  # 执行测试脚本
  log_info "执行测试脚本: $test_script"
  if bash "$test_script"; then
    log_success "=========================================="
    log_success "测试模式完成！所有测试通过。"
    log_success "=========================================="
    return 0
  else
    log_error "=========================================="
    log_error "测试模式失败！请检查测试日志。"
    log_error "=========================================="
    return 1
  fi
}

# ============================================
# 函数：parse_arguments
# 功能：解析命令行参数
# 参数：
#   $@ - 命令行参数
# ============================================
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --list-databases)
        list_databases
        exit 0
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --test)
        TEST_MODE=true
        shift
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        log_error "未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

# ============================================
# 函数：main
# 功能：主流程
# ============================================
main() {
  parse_arguments "$@"
  load_config
  validate_config

  log_info "=========================================="
  log_info "Noda 数据库备份系统"
  log_info "=========================================="

  acquire_lock

  # 测试模式（D-43）
  if [ "$TEST_MODE" = true ]; then
    run_test_mode
    local test_result=$?
    release_lock
    exit $test_result
  fi

  # 记录开始时间
  local start_time
  start_time=$(date +%s)

  # 健康检查
  log_info "步骤 1/7: 健康检查"
  if ! check_prerequisites; then
    send_alert "health_check_failed" "all" "健康检查失败"
    release_lock
    exit $EXIT_CONNECTION_FAILED
  fi
  log_success "健康检查通过"

  # 备份
  log_info "步骤 2/7: 备份数据库"
  local timestamp=$(get_timestamp)
  local date_path=$(get_date_path)
  local backup_dir="$(get_backup_dir)/$date_path"
  mkdir -p "$backup_dir"

  if [ "$DRY_RUN" = true ]; then
    log_warn "模拟模式：跳过实际备份"
    log_info "备份目录: $backup_dir"
    log_info "时间戳: $timestamp"
    release_lock
    exit 0
  fi

  if ! backup_all_databases "$backup_dir" "$timestamp"; then
    send_alert "backup_failed" "all" "备份失败"
    release_lock
    exit $EXIT_BACKUP_FAILED
  fi
  log_success "数据库备份完成"

  # 记录备份指标
  local backup_end_time
  backup_end_time=$(date +%s)
  local backup_duration=$((backup_end_time - start_time))

  # 验证
  log_info "步骤 3/7: 验证备份"
  local metadata_file="$backup_dir/metadata_$timestamp.json"
  if ! verify_all_backups "$backup_dir" "$metadata_file"; then
    send_alert "verification_failed" "all" "备份验证失败"
    release_lock
    exit $EXIT_VERIFICATION_FAILED
  fi
  log_success "备份验证完成"

  # 云上传（Phase 2）
  log_info "步骤 4/7: 上传到云存储"
  local upload_start_time
  upload_start_time=$(date +%s)

  if ! upload_to_b2 "$backup_dir"; then
    send_alert "upload_failed" "all" "云上传失败，但本地备份已保留"
    log_error "本地备份路径: $backup_dir"
    release_lock
    exit $EXIT_CLOUD_UPLOAD_FAILED
  fi

  local upload_end_time
  upload_end_time=$(date +%s)
  local upload_duration=$((upload_end_time - upload_start_time))
  log_success "云上传完成"

  # 清理旧备份
  log_info "步骤 5/7: 清理旧备份"
  cleanup_old_backups "$(get_backup_dir)"
  cleanup_old_backups_b2 $(get_retention_days)
  log_success "旧备份清理完成"

  # 清理旧历史记录（Phase 5）
  log_info "步骤 6/7: 清理旧历史记录"
  cleanup_old_metrics
  cleanup_old_alerts
  log_success "旧历史记录清理完成"

  # 记录指标并检查异常
  log_info "步骤 7/7: 记录指标"
  local databases=$(discover_databases)
  for db in $databases; do
    # 获取备份文件大小
    local backup_file="$backup_dir/${db}_${timestamp}.dump"
    local file_size=0
    if [[ -f "$backup_file" ]]; then
      file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
    fi

    # 记录备份指标
    record_metric "backup" "$db" "$backup_duration" "$file_size"

    # 记录上传指标
    record_metric "upload" "$db" "$upload_duration" "$file_size"

    # 检查备份耗时异常
    check_duration_anomaly "$db" "backup" "$backup_duration"

    # 检查上传耗时异常
    check_duration_anomaly "$db" "upload" "$upload_duration"
  done
  log_success "指标记录完成"

  # 完成
  log_success "=========================================="
  log_success "备份成功完成！"
  log_success "备份目录: $backup_dir"
  log_success "元数据文件: $metadata_file"
  log_success "云存储: 已上传到 B2"
  log_success "总耗时: ${backup_duration}s (备份) + ${upload_duration}s (上传)"
  log_success "=========================================="

  release_lock
  exit 0
}

# 捕获退出信号，确保释放锁
trap release_lock EXIT INT TERM

# 执行主流程
main "$@"
