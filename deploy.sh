#!/bin/bash
# Noda 基础设施自动部署脚本
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

INFRA_DIR="$HOME/project/noda-infra"
DOCKER_DIR="$INFRA_DIR/docker"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Noda 基础设施部署${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

cd "$DOCKER_DIR"
echo -e "${YELLOW}📁 工作目录：$(pwd)${NC}"
echo ""

echo -e "${YELLOW}📥 拉取最新代码...${NC}"
cd "$INFRA_DIR"
git pull origin main
echo -e "${GREEN}✅ 代码已更新${NC}"
echo ""

echo -e "${YELLOW}🌐 检查 Docker 网络...${NC}"
docker network create noda-network 2>/dev/null || echo "网络已存在"
echo -e "${GREEN}✅ 网络就绪${NC}"
echo ""

# 停止旧的 noda-dev-postgres 容器（如果存在）
echo -e "${YELLOW}🧹 清理旧的开发数据库容器...${NC}"
if docker ps -a | grep -q "noda-dev-postgres"; then
    docker stop noda-dev-postgres 2>/dev/null || echo "容器已停止"
    docker rm noda-dev-postgres 2>/dev/null || echo "容器已删除"
    echo -e "${GREEN}✅ 旧容器已清理${NC}"
else
    echo -e "${YELLOW}⚠️  未找到旧容器${NC}"
fi
echo ""

# 设置环境变量
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres_password_change_me
export POSTGRES_DB=noda_prod
export KEYCLOAK_ADMIN_USER=admin
export KEYCLOAK_ADMIN_PASSWORD=admin_password_change_me
export KEYCLOAK_DB_PASSWORD=keycloak_password_change_me

# 🔐 从加密配置文件读取密钥
echo -e "${YELLOW}🔐 加载加密密钥...${NC}"
if [ -f "$INFRA_DIR/config/secrets.sops.yaml" ]; then
    # 检查 sops 是否可用
    if command -v sops > /dev/null 2>&1; then
        # 使用 sops 解密并读取密钥
        SECRETS=$(sops --decrypt "$INFRA_DIR/config/secrets.sops.yaml")

        # 读取 Cloudflare Token
        TOKEN=$(echo "$SECRETS" | grep "^cloudflare_tunnel_token:" | awk '{print $2}' | tr -d '"')
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "" ]; then
            export CLOUDFLARE_TUNNEL_TOKEN="$TOKEN"
            echo -e "${GREEN}✅ Cloudflare Token 已加载${NC}"
        fi

        # 读取 Google OAuth 凭据
        GOOGLE_CLIENT_ID=$(echo "$SECRETS" | grep "^google_oauth_client_id:" | awk '{print $2}' | tr -d '"')
        GOOGLE_CLIENT_SECRET=$(echo "$SECRETS" | grep "^google_oauth_client_secret:" | awk '{print $2}' | tr -d '"')
        if [ -n "$GOOGLE_CLIENT_ID" ] && [ "$GOOGLE_CLIENT_SECRET" != "" ]; then
            export GOOGLE_OAUTH_CLIENT_ID="$GOOGLE_CLIENT_ID"
            export GOOGLE_OAUTH_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET"
            echo -e "${GREEN}✅ Google OAuth 凭据已加载${NC}"
        else
            echo -e "${YELLOW}⚠️  Google OAuth 凭据未配置${NC}"
        fi
    else
        echo -e "${RED}❌ sops 未安装，无法解密密钥文件${NC}"
        echo -e "${YELLOW}请安装 sops: brew install sops${NC}"
    fi
else
    echo -e "${YELLOW}⚠️  密钥文件不存在${NC}"
fi
echo ""

# 部署基础设施服务
echo -e "${YELLOW}🏗️  部署基础设施服务...${NC}"
cd "$DOCKER_DIR"

if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ] && [ "$CLOUDFLARE_TUNNEL_TOKEN" != "" ]; then
    docker compose -p noda-infra -f docker-compose.simple.yml up -d
else
    docker compose -p noda-infra -f docker-compose.simple.yml up -d postgres nginx keycloak
fi

echo ""
echo -e "${GREEN}✅ 基础设施服务已启动${NC}"

echo -e "${YELLOW}⏳ 等待数据库启动...${NC}"
sleep 5

echo -e "${YELLOW}🔧 检查数据库...${NC}"
docker exec noda-infra-postgres-1 psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='noda_prod'" | grep -q 1 || \
  docker exec noda-infra-postgres-1 psql -U postgres -c "CREATE DATABASE noda_prod;"
echo -e "${GREEN}✅ 生产数据库就绪${NC}"

echo -e "${YELLOW}🔧 检查开发数据库...${NC}"
docker exec noda-infra-postgres-dev-1 psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='noda_dev'" | grep -q 1 || \
  docker exec noda-infra-postgres-dev-1 psql -U postgres -c "CREATE DATABASE noda_dev;"
echo -e "${GREEN}✅ 开发数据库就绪${NC}"

echo -e "${YELLOW}🔧 检查 Keycloak 数据库...${NC}"
docker exec noda-infra-postgres-1 psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname='keycloak'" | grep -q 1 || \
  docker exec noda-infra-postgres-1 psql -U postgres -c "CREATE DATABASE keycloak;"
echo -e "${GREEN}✅ Keycloak 数据库就绪${NC}"

# 初始化 Keycloak realm
echo -e "${YELLOW}🔧 初始化 Keycloak realm...${NC}"
echo -e "${YELLOW}⏳ 等待 Keycloak 服务启动（最多 60 秒）...${NC}"

for i in {1..30}; do
  if curl -s http://localhost:8080/realms/master > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Keycloak 服务已启动${NC}"
    break
  fi

  if [ $i -eq 30 ]; then
    echo -e "${RED}❌ Keycloak 启动超时${NC}"
    exit 1
  fi

  sleep 2
done

# 登录 Keycloak 管理员
docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password 'admin_password_change_me' > /dev/null 2>&1

# 检查并创建 noda realm
if docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda > /dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Realm 'noda' 已存在${NC}"
else
  echo -e "${YELLOW}🏗️  创建 'noda' realm...${NC}"

  docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh create realms \
    -s realm=noda \
    -s enabled=true \
    -s sslRequired=none \
    -s registrationAllowed=true \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s bruteForceProtected=true > /dev/null 2>&1

  echo -e "${GREEN}✅ Realm 'noda' 创建成功${NC}"
fi

# 检查并创建 noda-frontend client
if docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/clients | jq -e '.[] | select(.clientId=="noda-frontend")' > /dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Client 'noda-frontend' 已存在${NC}"

  # 更新现有 client 的 redirect URIs
  CLIENT_ID=$(docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/clients | jq -r '.[] | select(.clientId=="noda-frontend") | .id')

  docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh update realms/noda/clients/$CLIENT_ID \
    -s 'redirectUris=["https://class.noda.co.nz/*", "http://localhost/*", "http://localhost:3000/*"]' \
    -s 'webOrigins=["https://class.noda.co.nz", "http://localhost", "http://localhost:3000"]' > /dev/null 2>&1

  echo -e "${GREEN}✅ Client 'noda-frontend' 已更新${NC}"
else
  echo -e "${YELLOW}🔧 创建 'noda-frontend' client...${NC}"

  docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh create clients \
    -r noda \
    -s clientId=noda-frontend \
    -s name=noda-frontend \
    -s enabled=true \
    -s publicClient=true \
    -s 'redirectUris=["https://class.noda.co.nz/*", "http://localhost/*", "http://localhost:3000/*"]' \
    -s 'webOrigins=["https://class.noda.co.nz", "http://localhost", "http://localhost:3000"]' > /dev/null 2>&1

  echo -e "${GREEN}✅ Client 'noda-frontend' 创建成功${NC}"
fi

# 配置 Google Identity Provider（如果环境变量存在）
if [ -n "$GOOGLE_OAUTH_CLIENT_ID" ] && [ -n "$GOOGLE_OAUTH_CLIENT_SECRET" ]; then
  echo -e "${YELLOW}🔗 配置 Google Identity Provider...${NC}"

  if docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google > /dev/null 2>&1; then
    docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh update realms/noda/identity-provider/instances/google \
      -s alias=google \
      -s providerId=google \
      -s displayName=Google \
      -s enabled=true \
      -s config.clientId="$GOOGLE_OAUTH_CLIENT_ID" \
      -s config.clientSecret="$GOOGLE_OAUTH_CLIENT_SECRET" \
      -s config.useJwksUrl=true > /dev/null 2>&1
  else
    docker exec noda-infra-keycloak-1 /opt/keycloak/bin/kcadm.sh create identity-provider/instances \
      -r noda \
      -s alias=google \
      -s providerId=google \
      -s displayName=Google \
      -s enabled=true \
      -s config.clientId="$GOOGLE_OAUTH_CLIENT_ID" \
      -s config.clientSecret="$GOOGLE_OAUTH_CLIENT_SECRET" \
      -s config.useJwksUrl=true > /dev/null 2>&1
  fi

  echo -e "${GREEN}✅ Google Identity Provider 配置成功${NC}"
else
  echo -e "${YELLOW}⚠️  Google OAuth 环境变量未设置，跳过 Google IdP 配置${NC}"
fi

echo -e "${GREEN}✅ Keycloak 初始化完成${NC}"

# 部署应用服务
echo -e "${YELLOW}🚀 部署应用服务 (web, api)...${NC}"
docker compose -p noda-app -f docker-compose.app.yml up -d --build

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ 部署完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${YELLOW}基础设施服务状态：${NC}"
docker compose -p noda-infra -f docker-compose.simple.yml ps
echo ""
echo -e "${YELLOW}应用服务状态：${NC}"
docker compose -p noda-app -f docker-compose.app.yml ps
echo ""
echo -e "${YELLOW}访问服务：${NC}"
echo "  前端: http://localhost/"
echo "  API: http://localhost/api/health"
echo "  Keycloak: http://localhost:8080/"
echo "  开发数据库: localhost:5433 (noda_dev)"
