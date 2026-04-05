#!/bin/bash

echo "🔍 Noda 环境快速验证"
echo ""

echo "容器状态:"
docker ps --filter "label=com.docker.compose.project.working_dir=/Users/dianwenwang/Project/noda-app" --format "  • {{.Names}} ({{.Status}})" 2>/dev/null || docker ps --format "  • {{.Names}} ({{.Status}})"
echo ""

echo "数据统计:"
if docker exec noda-postgres psql -U postgres -d findclass_db -c "SELECT 'Profiles', COUNT(*) FROM profiles UNION ALL SELECT 'Categories', COUNT(*) FROM categories UNION ALL SELECT 'Courses', COUNT(*) FROM courses;" 2>/dev/null; then
  :
else
  echo "  ⚠️  findclass_db 不可访问"
fi
echo ""

echo "API 测试:"
KEYCLOAK_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/realms/master)
if [ "$KEYCLOAK_STATUS" = "200" ]; then
  echo "  ✅ Keycloak API: HTTP $KEYCLOAK_STATUS"
else
  echo "  ❌ Keycloak API: HTTP $KEYCLOAK_STATUS"
fi
echo ""

echo "数据库列表:"
docker exec noda-postgres psql -U postgres -d postgres -c "\list" | grep -E "Name|postgres|keycloak|findclass" | head -5
echo ""

echo "网络状态:"
docker network ls | grep noda-network || echo "  ⚠️  noda-network 不存在"
