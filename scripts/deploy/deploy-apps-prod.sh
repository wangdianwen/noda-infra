#!/bin/bash
# 部署应用到生产环境

set -e

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🚀 开始部署应用: $IMAGE_TAG"

# 1. 验证基础设施服务运行
echo "🔍 验证基础设施服务..."
bash scripts/verify/verify-infrastructure.sh

# 2. 停止现有应用容器
echo "🛑 停止现有应用容器..."
docker-compose -f docker/docker-compose.prod.yml stop findclass-web findclass-api || true

# 3. 启动新版本应用
echo "🔄 启动新版本应用..."
DOCKER_IMAGE="$IMAGE_TAG" docker-compose -f docker/docker-compose.prod.yml up -d findclass-web findclass-api

# 4. 等待应用启动
echo "⏳ 等待应用启动..."
sleep 30

# 5. 验证应用状态
echo "✅ 验证应用状态..."
bash scripts/verify/verify-apps.sh

echo "✅ 应用部署完成！"
