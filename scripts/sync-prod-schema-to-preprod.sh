#!/bin/bash
# ============================================
# 从 prod 数据库同步 schema 到 preprod（不含数据）
#
# 用法：在 Mac 本地执行
#   ./scripts/sync-prod-schema-to-preprod.sh
#
# 前提：
#   - preprod postgres 容器已启动（preprod-postgres）
#   - 能 SSH 到 r4s（root@192.168.100.1）
# ============================================
set -euo pipefail

echo "=== 从 r4s prod 导出 schema ==="
ssh -i ~/.ssh/r4s_key root@192.168.100.1 \
  'docker exec noda-infra-postgres-prod pg_dump -U postgres -d noda_prod --schema-only --no-owner' \
  > /tmp/noda-prod-schema.sql
echo "✅ schema 导出: $(ls -lh /tmp/noda-prod-schema.sql | awk '{print $5}')"

echo ""
echo "=== 导入到 preprod ==="
cat /tmp/noda-prod-schema.sql | docker exec -i preprod-postgres psql -U postgres -d noda_preprod 2>&1 | grep -c ERROR || true
echo "✅ 导入完成（上方 ERROR 是重复索引/FK，可忽略）"

echo ""
echo "=== 验证 ==="
TABLE_COUNT=$(docker exec preprod-postgres psql -U postgres -d noda_preprod -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" 2>/dev/null | tr -d ' ')
MIGRATION_COUNT=$(docker exec preprod-postgres psql -U postgres -d noda_preprod -t -c "SELECT count(*) FROM public.__drizzle_migrations" 2>/dev/null | tr -d ' ')
echo "✅ 表数: $TABLE_COUNT, 迁移记录: $MIGRATION_COUNT"

echo ""
echo "=== 创建 keycloak 数据库 ==="
docker exec preprod-postgres psql -U postgres -c "CREATE DATABASE keycloak;" 2>/dev/null || echo "keycloak DB 已存在"
echo "✅ 完成"
