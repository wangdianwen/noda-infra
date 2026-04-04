#!/bin/bash
# 验证基础设施服务状态

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🔍 验证基础设施服务..."

# 检查容器状态
echo "📊 容器状态:"
docker-compose -f docker/docker-compose.yml ps

# 检查服务健康
echo "🏥 服务健康检查:"
for service in postgres keycloak nginx; do
  if docker-compose -f docker/docker-compose.yml ps | grep -q "$service.*Up"; then
    echo "✅ $service 运行中"
  else
    echo "❌ $service 未运行"
    exit 1
  fi
done

echo "✅ 所有基础设施服务正常！"
