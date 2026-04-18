#!/bin/bash
# ============================================
# Noda 数据库备份系统 - 恢复功能测试
# ============================================
# 功能：快速测试恢复功能
# ============================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "恢复功能快速测试"
echo "=========================================="
echo ""

# 加载配置
source lib/config.sh
load_config

pg_host=$(get_postgres_host)
pg_port=$(get_postgres_port)
pg_user=$(get_postgres_user)

# 测试 1: 创建测试数据库
echo "▶️  测试 1: 创建测试数据库"
docker exec noda-infra-postgres-prod psql -U postgres -d postgres \
    -c "DROP DATABASE IF EXISTS test_restore_quick;" >/dev/null 2>&1 || true

docker exec noda-infra-postgres-prod psql -U postgres -d postgres \
    -c "CREATE DATABASE test_restore_quick;" >/dev/null 2>&1

# 创建测试数据
docker exec -i noda-infra-postgres-prod psql -U postgres -d test_restore_quick >/dev/null 2>&1 <<SQL
CREATE TABLE users (id SERIAL PRIMARY KEY, name VARCHAR(100));
INSERT INTO users (name) VALUES ('Alice'), ('Bob'), ('Charlie');
SQL

echo "✅ 测试数据库创建成功"
echo ""

# 测试 2: 创建本地备份
echo "▶️  测试 2: 创建本地备份"
backup_file="/tmp/test_restore_quick_$(date +%Y%m%d_%H%M%S).sql"

docker exec noda-infra-postgres-prod pg_dump -U postgres test_restore_quick \
    --clean --if-exists >"$backup_file" 2>/dev/null

file_size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null)
echo "✅ 备份文件创建成功: $backup_file ($file_size bytes)"
echo ""

# 测试 3: 测试验证功能
echo "▶️  测试 3: 测试验证功能"
source lib/restore.sh

if verify_backup_integrity "$backup_file"; then
    echo "✅ 备份验证通过"
else
    echo "❌ 备份验证失败"
    exit 1
fi
echo ""

# 测试 4: 测试恢复功能
echo "▶️  测试 4: 测试恢复功能"
echo "yes" | restore_database "$backup_file" "test_restore_restored" >/dev/null 2>&1

# 验证恢复的数据
user_count=$(docker exec noda-infra-postgres-prod psql -U postgres -d test_restore_restored -t -c \
    "SELECT COUNT(*) FROM users;" 2>/dev/null | xargs)

if [[ "$user_count" -eq 3 ]]; then
    echo "✅ 恢复成功，数据完整（$user_count 条记录）"
else
    echo "❌ 恢复失败或数据不完整"
    exit 1
fi
echo ""

# 测试 5: 清理
echo "▶️  测试 5: 清理测试数据"
docker exec noda-infra-postgres-prod psql -U postgres -d postgres \
    -c "DROP DATABASE IF EXISTS test_restore_quick;" >/dev/null 2>&1 || true

docker exec noda-infra-postgres-prod psql -U postgres -d postgres \
    -c "DROP DATABASE IF EXISTS test_restore_restored;" >/dev/null 2>&1 || true

rm -f "$backup_file"
echo "✅ 清理完成"
echo ""

echo "=========================================="
echo "🎉 所有测试通过！"
echo "=========================================="
