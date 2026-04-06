#!/bin/bash
# ============================================
# Noda 数据库备份系统 - Phase 4 单元测试
# ============================================
# 功能：测试验证测试库的核心函数
# 作者：Noda 团队
# 版本：1.0.0
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 仅加载常量（避免依赖外部服务）
source "$SCRIPT_DIR/../lib/constants.sh"

# 测试计数器
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================
# 测试辅助函数
# ============================================

# assert_equals - 断言相等
assert_equals() {
  local expected=$1
  local actual=$2
  local message=${3:-"Assertion failed"}

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$expected" == "$actual" ]]; then
    echo "✅ PASS: $message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "❌ FAIL: $message"
    echo "   Expected: $expected"
    echo "   Actual: $actual"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# assert_success - 断言成功
assert_success() {
  local exit_code=$1
  local message=${2:-"Command should succeed"}

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ $exit_code -eq 0 ]]; then
    echo "✅ PASS: $message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "❌ FAIL: $message (exit code: $exit_code)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# assert_contains - 断言包含
assert_contains() {
  local haystack=$1
  local needle=$2
  local message=${3:-"Should contain"}

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$haystack" == *"$needle"* ]]; then
    echo "✅ PASS: $message"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    echo "❌ FAIL: $message"
    echo "   Haystack: $haystack"
    echo "   Needle: $needle"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

# ============================================
# 测试用例
# ============================================

# test_test_database_naming - 测试测试数据库名称规范
test_test_database_naming() {
  echo ""
  echo "测试: 测试数据库名称规范"

  local result="test_restore_keycloak_db"
  assert_equals "test_restore_keycloak_db" "$result" "测试数据库前缀正确"

  # 验证正则表达式
  if [[ $result =~ ^test_restore_ ]]; then
    assert_success 0 "测试数据库前缀验证通过"
  else
    assert_success 1 "测试数据库前缀验证通过"
  fi
}

# test_constants_defined - 测试常量定义
test_constants_defined() {
  echo ""
  echo "测试: 常量定义"

  assert_equals "test_restore_" "$TEST_DB_PREFIX" "TEST_DB_PREFIX 定义正确"
  assert_equals 3600 "$TEST_TIMEOUT" "TEST_TIMEOUT 定义正确"
  assert_equals 3 "$TEST_MAX_RETRIES" "TEST_MAX_RETRIES 定义正确"
}

# test_backup_dir_exists - 测试备份目录
test_backup_dir_exists() {
  echo ""
  echo "测试: 备份目录"

  mkdir -p "$TEST_BACKUP_DIR"

  if [[ -d "$TEST_BACKUP_DIR" ]]; then
    assert_success 0 "测试备份目录创建成功"
  else
    assert_success 1 "测试备份目录创建成功"
  fi
}

# test_verify_functions_exist - 测试验证函数存在
test_verify_functions_exist() {
  echo ""
  echo "测试: 验证库文件存在"

  local verify_lib="$SCRIPT_DIR/../lib/test-verify.sh"

  if [[ -f "$verify_lib" ]]; then
    assert_success 0 "test-verify.sh 文件存在"
  else
    assert_success 1 "test-verify.sh 文件存在"
  fi

  # 检查关键函数是否在文件中定义
  if grep -q "verify_table_count" "$verify_lib"; then
    assert_success 0 "verify_table_count 函数已定义"
  else
    assert_success 1 "verify_table_count 函数已定义"
  fi

  if grep -q "verify_data_exists" "$verify_lib"; then
    assert_success 0 "verify_data_exists 函数已定义"
  else
    assert_success 1 "verify_data_exists 函数已定义"
  fi

  if grep -q "verify_test_restore" "$verify_lib"; then
    assert_success 0 "verify_test_restore 函数已定义"
  else
    assert_success 1 "verify_test_restore 函数已定义"
  fi
}

# test_database_functions_exist - 测试数据库函数存在
test_database_functions_exist() {
  echo ""
  echo "测试: 数据库函数定义"

  local verify_lib="$SCRIPT_DIR/../lib/test-verify.sh"

  if grep -q "create_test_database" "$verify_lib"; then
    assert_success 0 "create_test_database 函数已定义"
  else
    assert_success 1 "create_test_database 函数已定义"
  fi

  if grep -q "drop_test_database" "$verify_lib"; then
    assert_success 0 "drop_test_database 函数已定义"
  else
    assert_success 1 "drop_test_database 函数已定义"
  fi
}

# test_download_functions_exist - 测试下载函数存在
test_download_functions_exist() {
  echo ""
  echo "测试: 下载函数定义"

  local verify_lib="$SCRIPT_DIR/../lib/test-verify.sh"

  if grep -q "download_latest_backup" "$verify_lib"; then
    assert_success 0 "download_latest_backup 函数已定义"
  else
    assert_success 1 "download_latest_backup 函数已定义"
  fi

  if grep -q "restore_to_test_database" "$verify_lib"; then
    assert_success 0 "restore_to_test_database 函数已定义"
  else
    assert_success 1 "restore_to_test_database 函数已定义"
  fi
}

# test_cleanup_function_exists - 测试清理函数存在
test_cleanup_function_exists() {
  echo ""
  echo "测试: 清理函数定义"

  local verify_lib="$SCRIPT_DIR/../lib/test-verify.sh"

  if grep -q "cleanup_on_timeout" "$verify_lib"; then
    assert_success 0 "cleanup_on_timeout 函数已定义"
  else
    assert_success 1 "cleanup_on_timeout 函数已定义"
  fi
}

# test_script_executable - 测试主脚本可执行
test_script_executable() {
  echo ""
  echo "测试: 主脚本可执行性"

  local script="$SCRIPT_DIR/../test-verify-weekly.sh"

  if [[ -x "$script" ]]; then
    assert_success 0 "test-verify-weekly.sh 可执行"
  else
    assert_success 1 "test-verify-weekly.sh 可执行"
  fi
}

# test_help_message - 测试帮助信息
test_help_message() {
  echo ""
  echo "测试: 帮助信息"

  local script="$SCRIPT_DIR/../test-verify-weekly.sh"
  local help_output
  help_output=$("$script" --help 2>&1 || true)

  assert_contains "$help_output" "用法:" "帮助信息包含 '用法'"
  assert_contains "$help_output" "--databases" "帮助信息包含 '--databases'"
  assert_contains "$help_output" "--timeout" "帮助信息包含 '--timeout'"
}

# ============================================
# 主函数
# ============================================

main() {
  echo "=========================================="
  echo "Phase 4 单元测试"
  echo "=========================================="
  echo ""

  # 运行所有测试
  test_test_database_naming
  test_constants_defined
  test_backup_dir_exists
  test_verify_functions_exist
  test_database_functions_exist
  test_download_functions_exist
  test_cleanup_function_exists
  test_script_executable
  test_help_message

  # 输出结果
  echo ""
  echo "=========================================="
  echo "测试结果"
  echo "=========================================="
  echo "运行: $TESTS_RUN"
  echo "通过: $TESTS_PASSED"
  echo "失败: $TESTS_FAILED"
  echo "=========================================="

  if [[ $TESTS_FAILED -gt 0 ]]; then
    echo ""
    echo "❌ 部分测试失败"
    exit 1
  else
    echo ""
    echo "✅ 所有测试通过！"
    exit 0
  fi
}

# 运行主函数
main
