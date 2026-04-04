#!/bin/bash
# 验证所有服务状态

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🔍 验证所有服务状态..."

# 检查容器状态
echo "📊 容器状态:"
docker-compose -f docker/docker-compose.yml ps

# 检查服务健康
echo "🏥 服务健康检查:"
services=("postgres" "keycloak" "nginx" "findclass-api" "findclass-web")

for service in "${services[@]}"; do
  if docker-compose -f docker/docker-compose.yml ps | grep -q "$service.*Up"; then
    echo "✅ $service 运行中"
  else
    echo "⚠️  $service 未运行（可能未启动）"
  fi
done

echo "✅ 服务验证完成！"
