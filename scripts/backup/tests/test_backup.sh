#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 备份功能测试
# ============================================
# 功能：测试备份功能的正确性
# 覆盖：BACKUP-01 到 BACKUP-05、VERIFY-01、MONITOR-04
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB_SCRIPT="$SCRIPT_DIR/create_test_db.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/../backup-postgres.sh"
TEST_DB_NAME="test_backup_db"

# 测试计数器
TESTS_PASSED=0
TESTS_FAILED=0

# 测试辅助函数
test_start() {
  echo "▶️  测试: $1"
}

test_pass() {
  echo "✅ 通过: $1"
  ((TESTS_PASSED++))
}

test_fail() {
  echo "❌ 失败: $1"
  echo "   原因: $2"
  ((TESTS_FAILED++))
}

# 测试 1: 健康检查（BACKUP-04）
test_health_check() {
  test_start "健康检查功能"

  if [ ! -f "$BACKUP_SCRIPT" ]; then
    test_fail "健康检查" "主脚本不存在，跳过测试"
    return
  fi

  # 测试 --dry-run 模式（包含健康检查）
  if bash "$BACKUP_SCRIPT" --dry-run > /tmp/test_dry_run.log 2>&1; then
    test_pass "健康检查"
  else
    test_fail "健康检查" "dry-run 模式执行失败"
  fi
}

# 测试 2: 列出数据库（BACKUP-01）
test_list_databases() {
  test_start "列出数据库功能"

  if [ ! -f "$BACKUP_SCRIPT" ]; then
    test_fail "列出数据库" "主脚本不存在，跳过测试"
    return
  fi

  local output=$(bash "$BACKUP_SCRIPT" --list-databases 2>&1)

  if echo "$output" | grep -q "keycloak_db\|findclass_db"; then
    test_pass "列出数据库"
  else
    test_fail "列出数据库" "未找到预期数据库"
  fi
}

# 测试 3: 创建测试数据库
test_create_test_db() {
  test_start "创建测试数据库"

  if [ ! -f "$TEST_DB_SCRIPT" ]; then
    test_fail "创建测试数据库" "测试数据库脚本不存在"
    return
  fi

  if bash "$TEST_DB_SCRIPT" --create > /tmp/test_create.log 2>&1; then
    test_pass "创建测试数据库"
  else
    test_fail "创建测试数据库" "执行失败"
  fi
}

# 测试 4: 执行备份（BACKUP-01, BACKUP-02, BACKUP-03）
test_perform_backup() {
  test_start "执行完整备份"

  if [ ! -f "$BACKUP_SCRIPT" ]; then
    test_fail "执行备份" "主脚本不存在，跳过测试"
    return
  fi

  # 执行备份
  if bash "$BACKUP_SCRIPT" > /tmp/test_backup.log 2>&1; then
    # 检查备份文件是否创建
    local backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"
    local latest_backup=$(find "$backup_dir" -name "*.dump" -type f 2>/dev/null | sort -r | head -1)

    if [ -n "$latest_backup" ]; then
      # 检查文件名格式（BACKUP-02）
      local filename=$(basename "$latest_backup")
      if echo "$filename" | grep -qE "^[a-z_]+_[0-9]{8}_[0-9]{6}\.dump$"; then
        test_pass "执行备份"
      else
        test_fail "执行备份" "文件名格式不符合要求: $filename"
      fi
    else
      test_fail "执行备份" "未找到备份文件"
    fi
  else
    test_fail "执行备份" "备份执行失败"
  fi
}

# 测试 5: 验证备份文件格式（BACKUP-03）
test_backup_format() {
  test_start "验证备份文件格式"

  local backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"
  local latest_backup=$(find "$backup_dir" -name "*.dump" -type f 2>/dev/null | sort -r | head -1)

  if [ -z "$latest_backup" ]; then
    test_fail "验证备份文件格式" "未找到备份文件"
    return
  fi

  # 使用 pg_restore --list 验证（VERIFY-01）
  if docker exec noda-infra-postgres-prod pg_restore --list "$latest_backup" > /dev/null 2>&1; then
    test_pass "验证备份文件格式"
  else
    test_fail "验证备份文件格式" "pg_restore --list 验证失败"
  fi
}

# 测试 6: 验证备份文件权限（BACKUP-02, D-13）
test_backup_permissions() {
  test_start "验证备份文件权限"

  local backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"
  local latest_backup=$(find "$backup_dir" -name "*.dump" -type f 2>/dev/null | sort -r | head -1)

  if [ -z "$latest_backup" ]; then
    test_fail "验证备份文件权限" "未找到备份文件"
    return
  fi

  # 检查文件权限
  local perms=$(stat -f "%Lp" "$latest_backup" 2>/dev/null || stat -c "%a" "$latest_backup" 2>/dev/null)

  if [ "$perms" = "600" ]; then
    test_pass "验证备份文件权限"
  else
    test_fail "验证备份文件权限" "权限不正确: $perms (期望: 600)"
  fi
}

# 测试 7: 清理测试数据库
test_cleanup_test_db() {
  test_start "清理测试数据库"

  if bash "$TEST_DB_SCRIPT" --cleanup > /tmp/test_cleanup.log 2>&1; then
    test_pass "清理测试数据库"
  else
    test_fail "清理测试数据库" "执行失败"
  fi
}

# 显示测试结果
show_results() {
  echo ""
  echo "=========================================="
  echo "测试结果"
  echo "=========================================="
  echo "✅ 通过: $TESTS_PASSED"
  echo "❌ 失败: $TESTS_FAILED"
  echo "总计: $((TESTS_PASSED + TESTS_FAILED))"

  if [ $TESTS_FAILED -eq 0 ]; then
    echo ""
    echo "🎉 所有测试通过！"
    return 0
  else
    echo ""
    echo "⚠️  存在失败的测试，请查看日志"
    return 1
  fi
}

# 主流程
main() {
  echo "=========================================="
  echo "Noda 数据库备份系统 - 备份功能测试"
  echo "=========================================="
  echo ""

  # 运行所有测试
  test_health_check
  test_list_databases
  test_create_test_db
  test_perform_backup
  test_backup_format
  test_backup_permissions
  test_cleanup_test_db

  # 显示结果
  show_results
}

main "$@"
