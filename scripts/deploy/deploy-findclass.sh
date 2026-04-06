#!/bin/bash
set -e

echo "=== Findclass 部署脚本 ==="

# 0. 解密密钥（如果存在加密文件）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$PROJECT_ROOT/secrets/infra.env.prod.enc" ]]; then
  echo "[0/4] 解密环境变量..."
  "$PROJECT_ROOT/scripts/decrypt-secrets.sh" infra /tmp/noda-secrets
  # 设置 COMPOSE 环境变量
  set -a
  source /tmp/noda-secrets/.env.prod
  set +a
  rm -f /tmp/noda-secrets/.env.prod
  echo "环境变量已加载并清理"
fi

# 1. 构建前端镜像前先动态生成 sitemap（需要数据库连接）
echo "[0/5] 生成 sitemap.xml..."
cd "$PROJECT_ROOT/../../noda-apps"
if command -v npx >/dev/null 2>&1; then
  npx tsx scripts/generate-sitemap.ts && echo "✓ sitemap.xml 已生成"
else
  echo "⚠ npx 不可用，跳过 sitemap 生成（将使用现有静态 sitemap）"
fi
cd "$PROJECT_ROOT"

# 2. 构建镜像
echo "[1/5] 构建前端镜像..."
docker build -f docker/Dockerfile.findclass -t noda-findclass:latest .

echo "[2/5] 构建 API 镜像..."
docker build -f docker/Dockerfile.api -t noda-api:latest .

# 3. 启动服务
echo "[3/5] 启动服务..."
cd docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --no-recreate findclass api

# 4. 等待容器启动
echo "[4/5] 等待容器就绪..."
sleep 10

# 5. 验证
echo "[5/5] 验证部署..."

echo "容器状态:"
docker compose -f docker-compose.yml -f docker-compose.prod.yml ps findclass api

echo ""
echo "前端健康检查:"
docker compose -f docker-compose.yml -f docker-compose.prod.yml exec findclass curl -sf http://localhost/health || echo "FAILED"

echo ""
echo "API 日志（最近 20 行）:"
docker compose -f docker-compose.yml -f docker-compose.prod.yml logs --tail=20 api

echo ""
echo "=== 部署完成 ==="
