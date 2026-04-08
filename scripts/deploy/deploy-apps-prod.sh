#!/bin/bash
# 部署 noda-apps 分组到生产环境
# findclass-ssr: API + SSR 渲染 + 静态文件（三合一服务）

set -e

IMAGE_TAG=${1:-"latest"}
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "🚀 开始部署 noda-apps: $IMAGE_TAG"

# 1. 验证基础设施服务运行
echo "🔍 验证基础设施服务..."
bash scripts/verify/verify-infrastructure.sh

# 2. 停止并删除现有应用容器
echo "🛑 停止现有应用容器..."
docker compose -f docker/docker-compose.app.yml down 2>/dev/null || true
# 兼容旧架构：删除可能存在的旧容器
docker stop findclass-ssr 2>/dev/null || true
docker rm findclass-ssr 2>/dev/null || true

# 3. 启动新版本应用
echo "🔄 启动新版本应用..."
docker compose -f docker/docker-compose.app.yml up -d --build

# 4. 等待应用启动
echo "⏳ 等待应用启动..."
sleep 30

# 5. 验证应用状态
echo "✅ 验证应用状态..."
docker compose -f docker/docker-compose.app.yml ps

echo "✅ noda-apps 部署完成！"
