#!/bin/bash
# Keycloak 初始化脚本
# 在 Keycloak 启动后自动创建 realm 和 client
# 注意：此脚本在 Keycloak 容器内执行，无法 source 外部日志库

set -e

MAX_RETRIES=30
RETRY_DELAY=2

echo -e "${YELLOW}⏳ 等待 Keycloak 启动...${NC}"

# 等待 Keycloak 启动
for i in $(seq 1 $MAX_RETRIES); do
  if curl -s http://localhost:8080/health/ready > /dev/null 2>&1 || \
     curl -s http://localhost:8080/realms/master > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Keycloak 已启动${NC}"
    break
  fi

  if [ $i -eq $MAX_RETRIES ]; then
    echo -e "${RED}❌ Keycloak 启动超时${NC}"
    exit 1
  fi

  echo "等待中... ($i/$MAX_RETRIES)"
  sleep $RETRY_DELAY
done

# 登录管理员
echo -e "${YELLOW}🔐 登录 Keycloak 管理员...${NC}"
/opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KEYCLOAK_ADMIN" \
  --password "$KEYCLOAK_ADMIN_PASSWORD"

# 检查 realm 是否已存在
if /opt/keycloak/bin/kcadm.sh get realms/noda > /dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Realm 'noda' 已存在，跳过创建${NC}"
else
  echo -e "${YELLOW}🏗️  创建 'noda' realm...${NC}"

  # 创建 realm（不包含 SSL 要求，允许 HTTP 开发）
  /opt/keycloak/bin/kcadm.sh create realms \
    -s realm=noda \
    -s enabled=true \
    -s sslRequired=none \
    -s registrationAllowed=true \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s bruteForceProtected=true

  echo -e "${GREEN}✅ Realm 'noda' 创建成功${NC}"
fi

# 检查 client 是否已存在
if /opt/keycloak/bin/kcadm.sh get realms/noda/clients | jq -e '.[] | select(.clientId=="noda-frontend")' > /dev/null 2>&1; then
  echo -e "${YELLOW}⚠️  Client 'noda-frontend' 已存在，跳过创建${NC}"
else
  echo -e "${YELLOW}🔧 创建 'noda-frontend' client...${NC}"

  # 创建 client
  CLIENT_ID=$(/opt/keycloak/bin/kcadm.sh create clients \
    -r noda \
    -s clientId=noda-frontend \
    -s name=noda-frontend \
    -s enabled=true \
    -s clientAuthenticatorType=client-secret \
    -s secret=YOUR_CLIENT_SECRET_HERE \
    -s publicClient=true \
    -s redirectUris=\"*\" \
    -s webOrigils=\"+\" \
    -i)

  echo -e "${GREEN}✅ Client 'noda-frontend' 创建成功${NC}"
fi

# 配置 Google Identity Provider（如果环境变量存在）
if [ -n "$GOOGLE_OAUTH_CLIENT_ID" ] && [ -n "$GOOGLE_OAUTH_CLIENT_SECRET" ]; then
  echo -e "${YELLOW}🔗 配置 Google Identity Provider...${NC}"

  # 检查 IdP 是否已存在
  if /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google > /dev/null 2>&1; then
    echo -e "${YELLOW}⚠️  Google IdP 已存在，更新配置...${NC}"
    /opt/keycloak/bin/kcadm.sh update realms/noda/identity-provider/instances/google \
      -s alias=google \
      -s providerId=google \
      -s displayName=Google \
      -s enabled=true \
      -s config.clientId="$GOOGLE_OAUTH_CLIENT_ID" \
      -s config.clientSecret="$GOOGLE_OAUTH_CLIENT_SECRET" \
      -s config.useJwksUrl=true
  else
    /opt/keycloak/bin/kcadm.sh create identity-provider/instances \
      -r noda \
      -s alias=google \
      -s providerId=google \
      -s displayName=Google \
      -s enabled=true \
      -s config.clientId="$GOOGLE_OAUTH_CLIENT_ID" \
      -s config.clientSecret="$GOOGLE_OAUTH_CLIENT_SECRET" \
      -s config.useJwksUrl=true
  fi

  echo -e "${GREEN}✅ Google Identity Provider 配置成功${NC}"
else
  echo -e "${YELLOW}⚠️  Google OAuth 环境变量未设置，跳过 Google IdP 配置${NC}"
fi

echo -e "${GREEN}✅ Keycloak 初始化完成！${NC}"
