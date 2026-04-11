#!/bin/bash
set -euo pipefail

# ============================================
# Keycloak 完整初始化脚本
# ============================================
# 功能：自动创建 realm、client 和 Google Identity Provider
# 用途：一键配置 Keycloak 认证服务
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# 步骤 1: 解密密钥
# ============================================
log_info "步骤 1/6: 解密 Google OAuth 凭据"

export SOPS_AGE_KEY_FILE="$PROJECT_ROOT/config/keys/git-age-key.txt"

# 解密并提取凭据
SECRETS=$(sops --decrypt "$PROJECT_ROOT/config/secrets.sops.yaml" 2>/dev/null)

GOOGLE_CLIENT_ID=$(echo "$SECRETS" | grep "google_oauth_client_id:" | cut -d' ' -f2)
GOOGLE_CLIENT_SECRET=$(echo "$SECRETS" | grep "google_oauth_client_secret:" | cut -d' ' -f2)

if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  log_error "无法解密 Google OAuth 凭据"
  exit 1
fi

log_success "凭据解密成功"
log_info "Client ID: ${GOOGLE_CLIENT_ID:0:20}..."

# ============================================
# 步骤 2: 检查容器
# ============================================
log_info "步骤 2/6: 检查 Keycloak 容器"

if ! docker ps --format "{{.Names}}" | grep -q "noda-infra-keycloak-prod"; then
  log_error "Keycloak 容器未运行"
  exit 1
fi

log_success "Keycloak 容器运行正常"

# ============================================
# 步骤 3: 登录管理员
# ============================================
log_info "步骤 3/6: 登录 Keycloak 管理员"

KEYCLOAK_ADMIN_PASSWORD=$(docker exec noda-infra-keycloak-prod printenv KEYCLOAK_ADMIN_PASSWORD)

if [ -z "$KEYCLOAK_ADMIN_PASSWORD" ]; then
  log_error "无法获取管理员密码"
  exit 1
fi

docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user admin \
  --password "$KEYCLOAK_ADMIN_PASSWORD" > /dev/null 2>&1

log_success "管理员登录成功"

# ============================================
# 步骤 4: 创建/更新 realm
# ============================================
log_info "步骤 4/6: 创建 noda realm"

if docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh get realms/noda > /dev/null 2>&1; then
  log_info "Realm 'noda' 已存在"
else
  log_info "创建 realm 'noda'..."

  docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh create realms \
    -s realm=noda \
    -s enabled=true \
    -s sslRequired=none \
    -s registrationAllowed=true \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s bruteForceProtected=true > /dev/null 2>&1

  log_success "Realm 'noda' 创建成功"
fi

# ============================================
# 步骤 5: 创建/更新 client
# ============================================
log_info "步骤 5/6: 创建 noda-frontend client"

# 创建 client JSON 配置（修复 CORS）
CLIENT_JSON=$(mktemp /tmp/noda-frontend-client.json.XXXXXX)
trap "rm -f $CLIENT_JSON" EXIT
cat > "$CLIENT_JSON" << 'EOF'
{
  "clientId": "noda-frontend",
  "name": "noda-frontend",
  "enabled": true,
  "publicClient": true,
  "redirectUris": [
    "https://class.noda.co.nz/*",
    "https://auth.noda.co.nz/*",
    "http://localhost:*"
  ],
  "webOrigins": [
    "https://class.noda.co.nz",
    "https://auth.noda.co.nz",
    "https://noda.co.nz",
    "http://localhost:*"
  ]
}
EOF

docker cp "$CLIENT_JSON" noda-infra-keycloak-prod:/tmp/client.json > /dev/null 2>&1

# 检查 client 是否已存在（缓存结果避免重复查询）
CLIENTS_JSON=$(docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh get realms/noda/clients)
if echo "$CLIENTS_JSON" | jq -e '.[] | select(.clientId=="noda-frontend")' > /dev/null 2>&1; then
  log_info "Client 'noda-frontend' 已存在，更新 CORS 配置..."

  CLIENT_ID=$(echo "$CLIENTS_JSON" | jq -r '.[] | select(.clientId=="noda-frontend") | .id')
  docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh update realms/noda/clients/$CLIENT_ID \
    -s 'webOrigins=["https://class.noda.co.nz", "https://auth.noda.co.nz", "https://noda.co.nz", "http://localhost:*"]' \
    -s 'redirectUris=["https://class.noda.co.nz/*", "https://auth.noda.co.nz/*", "http://localhost:*"]' > /dev/null 2>&1

  log_success "Client CORS 配置已更新"
else
  docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh create clients -r noda -f /tmp/client.json > /dev/null 2>&1
  log_success "Client 'noda-frontend' 创建成功"
fi

# ============================================
# 步骤 6: 配置 Google Identity Provider
# ============================================
log_info "步骤 6/6: 配置 Google Identity Provider"

GOOGLE_IDP_ARGS=(
  -s alias=google
  -s providerId=google
  -s displayName=Google
  -s enabled=true
  -s "config.clientId=$GOOGLE_CLIENT_ID"
  -s "config.clientSecret=$GOOGLE_CLIENT_SECRET"
  -s config.useJwksUrl=true
  -s "config.redirectUri=https://auth.noda.co.nz/realms/noda/broker/google/endpoint"
)

# 检查 IdP 是否已存在
if docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh get realms/noda/identity-provider/instances/google > /dev/null 2>&1; then
  log_info "Google IdP 已存在，更新配置..."
  docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh update realms/noda/identity-provider/instances/google \
    "${GOOGLE_IDP_ARGS[@]}" > /dev/null 2>&1
else
  log_info "创建 Google IdP..."
  docker exec noda-infra-keycloak-prod /opt/keycloak/bin/kcadm.sh create identity-provider/instances \
    -r noda "${GOOGLE_IDP_ARGS[@]}" > /dev/null 2>&1
fi

log_success "Google Identity Provider 配置成功"

# ============================================
# 验证配置
# ============================================

log_success "=========================================="
log_success "Keycloak 配置完成！"
log_success "=========================================="
log_info "✓ Realm: noda"
log_info "✓ Client: noda-frontend"
log_info "✓ Google OAuth: 已配置"
log_info ""
log_info "访问地址："
log_info "  管理控制台: https://auth.noda.co.nz/admin"
log_info "  Realm 端点: https://auth.noda.co.nz/realms/noda"
log_info "  Google OAuth: https://auth.noda.co.nz/realms/noda/broker/google/endpoint"
log_success "=========================================="
