#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 每周验证测试
# ============================================
# 功能：每周自动从 B2 下载最新备份，恢复到临时数据库并验证
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载依赖库
source "$SCRIPT_DIR/lib/constants.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/test-verify.sh"
source "$SCRIPT_DIR/lib/alert.sh"
source "$SCRIPT_DIR/lib/metrics.sh"

# 全局变量
TEST_START_TIME=$(date +%s)
TEST_STATUS="success"
CLEANUP_NEEDED=false
TEST_DB_NAME=""

# 测试数据库列表（可通过环境变量覆盖）
TEST_DATABASES="${TEST_DATABASES:-}"

# ============================================
# 清理函数
# ============================================

# cleanup - 清理临时资源
cleanup() {
  local exit_code=$?

  if [[ "$CLEANUP_NEEDED" == "true" ]]; then
    log_info "开始清理临时资源..."

    # 清理临时数据库
    if [[ -n "$TEST_DB_NAME" ]]; then
      if [[ $exit_code -eq 0 ]]; then
        drop_test_database "$TEST_DB_NAME" 2>/dev/null || true
      else
        log_warn "测试失败，保留临时数据库供调试: $TEST_DB_NAME"
      fi
    fi

    # 清理临时文件
    rm -rf "$TEST_BACKUP_DIR" 2>/dev/null || true
  fi

  # 输出最终状态
  local test_end_time=$(date +%s)
  local total_duration=$((test_end_time - TEST_START_TIME))

  log_info "测试结束，退出码: $exit_code，总耗时: ${total_duration}s"
  exit $exit_code
}

# 捕获中断信号
trap cleanup EXIT INT TERM

# ============================================
# 超时处理
# ============================================

# timeout_handler - 超时处理函数
timeout_handler() {
  log_error "测试超时（${TEST_TIMEOUT}秒）"
  TEST_STATUS="timeout"

  # 强制清理
  cleanup_on_timeout

  exit $EXIT_TIMEOUT
}

# ============================================
# 辅助函数
# ============================================

# check_environment - 检查测试环境
check_environment() {
  log_info "检查测试环境..."

  # 检查 PostgreSQL 连接
  local pg_host
  local pg_port
  local pg_user
  pg_host=$(get_postgres_host)
  pg_port=$(get_postgres_port)
  pg_user=$(get_postgres_user)

  if ! pg_isready -h "$pg_host" -p "$pg_port" -U "$pg_user" >/dev/null 2>&1; then
    log_error "PostgreSQL 连接失败"
    exit $EXIT_CONNECTION_FAILED
  fi
  log_success "PostgreSQL 连接正常"

  # 检查磁盘空间
  local available_space
  available_space=$(df -h "$TEST_BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown")
  log_info "可用磁盘空间: $available_space"

  # 检查 B2 配置
  if ! validate_b2_credentials >/dev/null 2>&1; then
    log_error "B2 配置缺失或无效"
    exit $EXIT_INVALID_ARGS
  fi
  log_success "B2 配置验证通过"

  # 创建临时目录
  mkdir -p "$TEST_BACKUP_DIR"
  mkdir -p "$(dirname "$TEST_LOG_DIR")" 2>/dev/null || true

  log_success "环境检查通过"
}

# print_summary - 打印测试总结
print_summary() {
  local test_end_time=$(date +%s)
  local total_duration=$((test_end_time - TEST_START_TIME))

  echo ""
  echo "=========================================="
  echo "测试总结"
  echo "=========================================="
  echo "总耗时: ${total_duration} 秒"
  echo "状态: $TEST_STATUS"
  echo "测试时间: $(date -u -d @$TEST_START_TIME +'%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || date -u -r $TEST_START_TIME +'%Y-%m-%d %H:%M:%S UTC')"
  echo "=========================================="
}

# ============================================
# 单数据库测试
# ============================================

# test_single_database - 测试单个数据库
# 参数：
#   $1: 数据库名
test_single_database() {
  local db_name=$1
  local db_start_time=$(date +%s)

  log_info "=========================================="
  log_info "测试数据库: $db_name"
  log_info "=========================================="

  CLEANUP_NEEDED=true

  # 1. 下载最新备份
  log_info "步骤 1/5: 下载最新备份"
  local backup_file
  backup_file=$(download_latest_backup "$db_name")

  if [[ ! -f "$backup_file" ]]; then
    log_error "下载失败: $db_name"
    send_alert "test_download_failed" "$db_name" "验证测试：下载备份失败"
    TEST_STATUS="download_failed"
    return $EXIT_DOWNLOAD_FAILED
  fi

  # 2. 创建测试数据库
  log_info "步骤 2/5: 创建测试数据库"
  local test_db
  test_db=$(create_test_database "$db_name")

  if [[ -z "$test_db" ]]; then
    log_error "测试数据库创建失败"
    send_alert "test_create_db_failed" "$db_name" "验证测试：创建测试数据库失败"
    TEST_STATUS="create_db_failed"
    return $EXIT_RESTORE_TEST_FAILED
  fi

  TEST_DB_NAME="$test_db"

  # 3. 恢复数据
  log_info "步骤 3/5: 恢复数据"
  if ! restore_to_test_database "$backup_file" "$test_db"; then
    log_error "恢复失败: $db_name"
    send_alert "test_restore_failed" "$db_name" "验证测试：恢复数据失败"
    TEST_STATUS="restore_failed"
    return $EXIT_RESTORE_TEST_FAILED
  fi

  # 4. 验证数据
  log_info "步骤 4/5: 验证数据"
  if ! verify_test_restore "$test_db" "$backup_file"; then
    log_error "验证失败: $db_name"
    send_alert "test_verify_failed" "$db_name" "验证测试：数据验证失败"
    TEST_STATUS="verify_failed"
    return $EXIT_VERIFY_TEST_FAILED
  fi

  # 5. 记录指标并检查异常
  log_info "步骤 5/5: 记录指标"

  local db_end_time=$(date +%s)
  local db_duration=$((db_end_time - db_start_time))

  # 获取备份文件大小
  local file_size=0
  if [[ -f "$backup_file" ]]; then
    file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
  fi

  # 记录指标
  record_metric "verify_test" "$db_name" "$db_duration" "$file_size"

  # 检查耗时异常
  check_duration_anomaly "$db_name" "verify_test" "$db_duration"

  # 清理当前数据库
  drop_test_database "$test_db"
  rm -f "$backup_file"

  CLEANUP_NEEDED=false
  TEST_DB_NAME=""

  log_success "=========================================="
  log_success "数据库测试成功: $db_name (耗时: ${db_duration}s)"
  log_success "=========================================="
  echo ""

  return 0
}

# ============================================
# 主函数
# ============================================

main() {
  # 解析参数
  while [[ $# -gt 0 ]]; do
    case $1 in
      --help)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  --databases DBS    测试数据库列表（空格分隔）"
        echo "  --timeout SECONDS  超时时间（默认: 3600）"
        echo "  --help             显示此帮助信息"
        echo ""
        echo "环境变量:"
        echo "  POSTGRES_HOST       PostgreSQL 主机"
        echo "  POSTGRES_PORT       PostgreSQL 端口"
        echo "  POSTGRES_USER       PostgreSQL 用户"
        echo "  B2_ACCOUNT_ID       Backblaze B2 Account ID"
        echo "  B2_APPLICATION_KEY  Backblaze B2 Application Key"
        echo "  B2_BUCKET_NAME      Backblaze B2 Bucket 名称"
        exit 0
        ;;
      --databases)
        TEST_DATABASES="$2"
        shift 2
        ;;
      --timeout)
        TEST_TIMEOUT="$2"
        shift 2
        ;;
      *)
        echo "未知参数: $1"
        echo "使用 --help 查看帮助信息"
        exit $EXIT_INVALID_ARGS
        ;;
    esac
  done

  # 设置超时
  trap timeout_handler ALRM
  timeout $TEST_TIMEOUT $$ 2>/dev/null || true

  # 加载配置
  load_config

  # 开始测试
  echo ""
  echo "=========================================="
  log_info "每周备份验证测试开始"
  log_info "测试时间: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
  echo "=========================================="
  echo ""

  # 环境检查
  check_environment

  # 获取测试数据库列表
  local databases
  if [[ -z "$TEST_DATABASES" ]]; then
    # 从配置读取或使用默认值
    databases="keycloak_db findclass_db"
  else
    databases="$TEST_DATABASES"
  fi

  log_info "测试数据库列表: $databases"
  echo ""

  # 测试所有数据库
  local failed_count=0
  for db in $databases; do
    if ! test_single_database "$db"; then
      ((failed_count++)) || true
    fi
  done

  # 清理旧历史记录
  log_info "清理旧历史记录..."
  cleanup_old_metrics
  cleanup_old_alerts
  log_success "旧历史记录清理完成"

  # 输出总结
  print_summary

  # 检查结果
  if [[ $failed_count -eq 0 ]]; then
    log_success "=========================================="
    log_success "所有测试通过！"
    log_success "=========================================="
    exit 0
  else
    log_error "=========================================="
    log_error "部分测试失败: $failed_count 个数据库"
    send_alert "weekly_test_failed" "all" "每周验证测试：$failed_count 个数据库失败"
    log_error "=========================================="
    exit 1
  fi
}

# 运行主函数
main "$@"
