#!/bin/bash
set -e

echo "=== Findclass 端到端验证脚本 ==="
echo ""

# 检查容器状态
echo "1. 检查容器状态..."
echo ""

cd /Users/dianwenwang/Project/oneteam/infra/docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps findclass api --format "table {{.Name}}\t{{.Status}}"

echo ""
echo "2. 前端健康检查..."
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T findclass curl -sf http://localhost/health && echo " ✓ PASSED" || echo " ✗ FAILED"

echo ""
echo "3. API 健康检查（通过 Nginx 代理）..."
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T nginx curl -sf http://class.noda.co.nz/api/health > /dev/null && echo " ✓ PASSED" || echo " ✗ FAILED"

echo ""
echo "4. 前端页面加载..."
TITLE=$(docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T nginx curl -sf http://class.noda.co.nz/ | grep -o "<title>.*</title>")
if [[ "$TITLE" == *"findclass"* ]]; then
  echo " ✓ PASSED: $TITLE"
else
  echo " ✗ FAILED: $TITLE"
fi

echo ""
echo "5. SPA 路由（测试 /some-page 不返回 404）..."
HTTP_STATUS=$(docker compose -f docker-compose.yml -f docker-compose.prod.yml exec -T nginx curl -sI http://class.noda.co.nz/some-page | grep "HTTP/" | awk '{print $2}')
if [[ "$HTTP_STATUS" == "200" ]]; then
  echo " ✓ PASSED: HTTP $HTTP_STATUS"
else
  echo " ✗ FAILED: HTTP $HTTP_STATUS"
fi

echo ""
echo "6. API 日志（最近 5 行）..."
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail=5 api

echo ""
echo "=== 验证完成 ==="
echo ""
echo "注意：Keycloak Client 配置需要手动验证"
echo "访问 http://localhost:8080 并检查 noda-frontend client 的 Redirect URIs"
