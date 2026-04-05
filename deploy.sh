#!/bin/bash
# OneTeam 基础设施自动部署脚本
# 用法：./deploy.sh [force]

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 项目路径
INFRA_DIR="$HOME/project/noda-infra"
DOCKER_DIR="$INFRA_DIR/docker"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OneTeam 基础设施部署${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# 检查目录是否存在
if [ ! -d "$DOCKER_DIR" ]; then
    echo -e "${RED}❌ 错误：项目目录不存在 $DOCKER_DIR${NC}"
    exit 1
fi

# 进入项目目录
cd "$DOCKER_DIR"
echo -e "${YELLOW}📁 工作目录：$(pwd)${NC}"
echo ""

# 拉取最新代码
echo -e "${YELLOW}📥 拉取最新代码...${NC}"
cd "$INFRA_DIR"
git pull origin main
echo -e "${GREEN}✅ 代码已更新${NC}"
echo ""

# 部署服务
echo -e "${YELLOW}🚀 部署服务...${NC}"
cd "$DOCKER_DIR"

# 设置环境变量
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres_password_change_me
export POSTGRES_DB=oneteam_prod
export KEYCLOAK_ADMIN_USER=admin
export KEYCLOAK_ADMIN_PASSWORD=admin_password_change_me
export KEYCLOAK_DB_PASSWORD=keycloak_password_change_me
export CLOUDFLARE_TUNNEL_TOKEN=

# 启动服务
docker compose -p noda-prod -f docker-compose.yml up -d --build

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}查看服务状态：${NC}"
docker compose -p noda-prod -f docker-compose.yml ps
echo ""
echo -e "${YELLOW}查看日志：${NC}"
echo "docker compose -p noda-prod -f docker-compose.yml logs -f [服务名]"
