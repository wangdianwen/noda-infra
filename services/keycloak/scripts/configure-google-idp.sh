#!/bin/bash
set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Keycloak Admin API 端点
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
REALM="${KEYCLOAK_REALM:-noda}"
ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}"

# Google OAuth 配置
GOOGLE_CLIENT_ID="${GOOGLE_OAUTH_CLIENT_ID}"
GOOGLE_CLIENT_SECRET="${GOOGLE_OAUTH_CLIENT_SECRET}"

echo -e "${GREEN}=== Keycloak Google Identity Provider 配置脚本 ===${NC}"

# 检查必需的环境变量
if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  echo -e "${RED}错误: 缺少必需的环境变量${NC}"
  echo "请设置 GOOGLE_OAUTH_CLIENT_ID 和 GOOGLE_OAUTH_CLIENT_SECRET"
  exit 1
fi

if [ -z "$ADMIN_PASSWORD" ]; then
  echo -e "${RED}错误: 缺少 KEYCLOAK_ADMIN_PASSWORD 环境变量${NC}"
  exit 1
fi

# 获取 Admin Token
echo -e "${YELLOW}正在获取 Keycloak Admin Token...${NC}"
ADMIN_TOKEN=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "$ADMIN_TOKEN" == "null" ] || [ -z "$ADMIN_TOKEN" ]; then
  echo -e "${RED}错误: 无法获取 Admin Token${NC}"
  echo "请检查 KEYCLOAK_ADMIN_USER 和 KEYCLOAK_ADMIN_PASSWORD 是否正确"
  exit 1
fi

echo -e "${GREEN}Admin Token 获取成功${NC}"

# 创建 Google Identity Provider
echo -e "${YELLOW}正在配置 Google Identity Provider...${NC}"
curl -s -X POST "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "alias": "google",
    "providerId": "google",
    "displayName": "Google",
    "enabled": true,
    "firstBrokerLoginFlowAlias": "firstBrokerLogin",
    "config": {
      "clientId": "'"${GOOGLE_CLIENT_ID}"'",
      "clientSecret": "'"${GOOGLE_CLIENT_SECRET}"'",
      "hostedDomain": "",
      "useJwksUrl": "true"
    }
  }' > /dev/null

echo -e "${GREEN}Google Identity Provider 配置成功${NC}"

# 验证配置
echo -e "${YELLOW}正在验证配置...${NC}"
IDP_LIST=$(curl -s "${KEYCLOAK_URL}/admin/realms/${REALM}/identity-provider/instances" \
  -H "Authorization: Bearer ${ADMIN_TOKEN}")

if echo "$IDP_LIST" | jq -e '.[] | select(.alias == "google")' > /dev/null; then
  echo -e "${GREEN}验证成功: Google Identity Provider 已启用${NC}"
else
  echo -e "${RED}验证失败: Google Identity Provider 未找到${NC}"
  exit 1
fi

# 输出后续步骤
echo ""
echo -e "${GREEN}=== 配置完成 ===${NC}"
echo ""
echo -e "${YELLOW}下一步操作:${NC}"
echo "1. 在 Google Cloud Console 中添加回调 URL:"
echo "   ${GREEN}https://keycloak.noda.co.nz/realms/${REALM}/broker/google/endpoint${NC}"
echo ""
echo "2. 在 Keycloak Admin Console 中验证配置:"
echo "   ${GREEN}${KEYCLOAK_URL}/admin/master/console/#/realms/${REALM}/identity-providers${NC}"
echo ""
echo "3. 测试 Google OAuth 登录:"
echo "   ${GREEN}bash scripts/test-google-oauth.sh${NC}"
echo ""
