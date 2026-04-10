#!/bin/bash
set -euo pipefail

# ============================================
# Noda 数据库备份系统 - 测试数据库创建脚本
# ============================================
# 功能：创建测试数据库用于备份和恢复测试
# 用法：./create_test_db.sh [选项]
# 选项：
#   --create    创建测试数据库（默认）
#   --cleanup   清理测试数据库
#   --help      显示帮助信息
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DB_NAME="test_backup_db"
POSTGRES_CONTAINER="noda-infra-postgres-prod"

# 创建测试数据库
create_test_database() {
  echo "ℹ️  创建测试数据库: $TEST_DB_NAME"

  # 检查数据库是否已存在
  local exists=$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -t -c \
    "SELECT 1 FROM pg_database WHERE datname = '$TEST_DB_NAME';" 2>/dev/null | tr -d ' ')

  if [ "$exists" = "1" ]; then
    echo "⚠️  测试数据库已存在，先删除"
    cleanup_test_database
  fi

  # 创建数据库
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -c \
    "CREATE DATABASE $TEST_DB_NAME;"

  # 创建测试表并插入数据
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d "$TEST_DB_NAME" <<EOF
-- 创建测试表
CREATE TABLE test_users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 插入测试数据
INSERT INTO test_users (username, email) VALUES
    ('test_user_1', 'user1@test.com'),
    ('test_user_2', 'user2@test.com'),
    ('test_user_3', 'user3@test.com');

-- 创建测试表 2
CREATE TABLE test_posts (
    id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    content TEXT,
    author_id INTEGER REFERENCES test_users(id),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 插入测试数据
INSERT INTO test_posts (title, content, author_id) VALUES
    ('Test Post 1', 'Content of test post 1', 1),
    ('Test Post 2', 'Content of test post 2', 2);
EOF

  echo "✅ 测试数据库创建成功: $TEST_DB_NAME"
  echo "ℹ️  测试表: test_users, test_posts"
  echo "ℹ️  测试数据: 3 users, 2 posts"
}

# 清理测试数据库
cleanup_test_database() {
  echo "ℹ️  清理测试数据库: $TEST_DB_NAME"

  local exists=$(docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -t -c \
    "SELECT 1 FROM pg_database WHERE datname = '$TEST_DB_NAME';" 2>/dev/null | tr -d ' ')

  if [ "$exists" != "1" ]; then
    echo "⚠️  测试数据库不存在，无需清理"
    return 0
  fi

  # 终止所有连接
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$TEST_DB_NAME' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true

  # 删除数据库
  docker exec "$POSTGRES_CONTAINER" psql -U postgres -d postgres -c \
    "DROP DATABASE $TEST_DB_NAME;"

  echo "✅ 测试数据库已清理: $TEST_DB_NAME"
}

# 显示帮助
show_help() {
  cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --create    创建测试数据库（默认）
  --cleanup   清理测试数据库
  --help      显示帮助信息

示例:
  $(basename "$0")              # 创建测试数据库
  $(basename "$0") --cleanup    # 清理测试数据库
EOF
}

# 主流程
main() {
  local action="create"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --create)
        action="create"
        shift
        ;;
      --cleanup)
        action="cleanup"
        shift
        ;;
      --help)
        show_help
        exit 0
        ;;
      *)
        echo "❌ 未知参数: $1"
        show_help
        exit 1
        ;;
    esac
  done

  if [ "$action" = "create" ]; then
    create_test_database
  else
    cleanup_test_database
  fi
}

main "$@"
