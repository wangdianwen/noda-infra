#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 恢复功能测试
# ============================================
# 功能：测试恢复功能的正确性（D-43）
# 覆盖：完整备份和恢复流程验证
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB_SCRIPT="$SCRIPT_DIR/create_test_db.sh"
BACKUP_SCRIPT="$SCRIPT_DIR/../backup-postgres.sh"
TEST_DB_NAME="test_backup_db"
RESTORE_DB_NAME="${TEST_DB_NAME}_restore"

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

# 测试 1: 创建测试数据库并准备数据
test_prepare_test_data() {
  test_start "准备测试数据"

  if ! bash "$TEST_DB_SCRIPT" --create > /tmp/test_prepare.log 2>&1; then
    test_fail "准备测试数据" "创建测试数据库失败"
    return
  fi

  # 验证测试数据
  local count=$(docker exec noda-infra-postgres-prod psql -U postgres -d "$TEST_DB_NAME" -t -c \
    "SELECT COUNT(*) FROM test_users;" 2>/dev/null | tr -d ' ')

  if [ "$count" = "3" ]; then
    test_pass "准备测试数据"
  else
    test_fail "准备测试数据" "测试数据不正确: $count (期望: 3)"
  fi
}

# 测试 2: 执行备份
test_perform_backup() {
  test_start "执行备份"

  if ! bash "$BACKUP_SCRIPT" > /tmp/test_restore_backup.log 2>&1; then
    test_fail "执行备份" "备份执行失败"
    return
  fi

  # 获取最新备份文件
  local backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"
  local latest_backup=$(find "$backup_dir" -name "${TEST_DB_NAME}_*.dump" -type f 2>/dev/null | sort -r | head -1)

  if [ -n "$latest_backup" ]; then
    test_pass "执行备份"
  else
    test_fail "执行备份" "未找到测试数据库的备份文件"
  fi
}

# 测试 3: 恢复到新数据库
test_restore_to_new_db() {
  test_start "恢复到新数据库"

  local backup_dir="/var/lib/docker/volumes/noda-infra_postgres_data/_data/backup"
  local latest_backup=$(find "$backup_dir" -name "${TEST_DB_NAME}_*.dump" -type f 2>/dev/null | sort -r | head -1)

  if [ -z "$latest_backup" ]; then
    test_fail "恢复到新数据库" "未找到备份文件"
    return
  fi

  # 创建恢复数据库
  docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c \
    "DROP DATABASE IF EXISTS $RESTORE_DB_NAME;" > /dev/null 2>&1 || true
  docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c \
    "CREATE DATABASE $RESTORE_DB_NAME;" > /dev/null 2>&1

  # 执行恢复
  local backup_path="/var/lib/postgresql/backup/$(echo "$latest_backup" | grep -oP '\d{4}/\d{2}/\d{2}/\K[^/]+$')"
  if docker exec noda-infra-postgres-prod pg_restore -U postgres -d "$RESTORE_DB_NAME" \
      "/var/lib/postgresql/backup/$(basename "$latest_backup")" > /tmp/test_restore.log 2>&1; then
    test_pass "恢复到新数据库"
  else
    test_fail "恢复到新数据库" "pg_restore 执行失败"
  fi
}

# 测试 4: 验证恢复后的数据完整性
test_verify_restored_data() {
  test_start "验证恢复后的数据完整性"

  # 检查表是否存在
  local tables=$(docker exec noda-infra-postgres-prod psql -U postgres -d "$RESTORE_DB_NAME" -t -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ')

  if [ "$tables" != "2" ]; then
    test_fail "验证恢复后的数据完整性" "表数量不正确: $tables (期望: 2)"
    return
  fi

  # 检查数据是否完整
  local users_count=$(docker exec noda-infra-postgres-prod psql -U postgres -d "$RESTORE_DB_NAME" -t -c \
    "SELECT COUNT(*) FROM test_users;" 2>/dev/null | tr -d ' ')

  local posts_count=$(docker exec noda-infra-postgres-prod psql -U postgres -d "$RESTORE_DB_NAME" -t -c \
    "SELECT COUNT(*) FROM test_posts;" 2>/dev/null | tr -d ' ')

  if [ "$users_count" = "3" ] && [ "$posts_count" = "2" ]; then
    test_pass "验证恢复后的数据完整性"
  else
    test_fail "验证恢复后的数据完整性" "数据不完整: users=$users_count, posts=$posts_count"
  fi
}

# 测试 5: 清理测试数据库
test_cleanup_test_dbs() {
  test_start "清理测试数据库"

  bash "$TEST_DB_SCRIPT" --cleanup > /dev/null 2>&1 || true

  # 清理恢复数据库
  docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c \
    "DROP DATABASE IF EXISTS $RESTORE_DB_NAME;" > /dev/null 2>&1 || true

  test_pass "清理测试数据库"
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
  echo "Noda 数据库备份系统 - 恢复功能测试"
  echo "=========================================="
  echo ""

  # 运行所有测试
  test_prepare_test_data
  test_perform_backup
  test_restore_to_new_db
  test_verify_restored_data
  test_cleanup_test_dbs

  # 显示结果
  show_results
}

main "$@"
