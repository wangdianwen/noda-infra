#!/bin/bash
# 部署基础设施到生产环境

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🚀 开始部署基础设施..."

# 1. 验证环境
echo "📋 验证环境配置..."
bash scripts/utils/check-env.sh

# 2. 停止现有容器
echo "🛑 停止现有容器..."
docker-compose -f docker/docker-compose.prod.yml down

# 3. 启动基础设施服务
echo "🔄 启动基础设施服务..."
docker-compose -f docker/docker-compose.prod.yml up -d postgres keycloak nginx

# 4. 等待服务启动
echo "⏳ 等待服务启动..."
sleep 30

# 5. 验证服务状态
echo "✅ 验证服务状态..."
bash scripts/verify/verify-services.sh

echo "✅ 基础设施部署完成！"
