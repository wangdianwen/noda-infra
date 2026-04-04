#!/bin/bash
# 验证应用服务状态

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🔍 验证应用服务..."

# 检查容器状态
echo "📊 容器状态:"
docker-compose -f docker/docker-compose.prod.yml ps | grep findclass

# 检查服务健康
echo "🏥 服务健康检查:"

# 前端
if curl -f https://class.noda.co.nz > /dev/null 2>&1; then
  echo "✅ 前端运行正常"
else
  echo "❌ 前端访问失败"
  exit 1
fi

# API
if curl -f https://class.noda.co.nz/api/health > /dev/null 2>&1; then
  echo "✅ API 运行正常"
else
  echo "⚠️ API 健康检查端点未配置"
fi

echo "✅ 应用服务验证完成！"
