#!/bin/bash
set -euo pipefail

# ============================================
# Keycloak Realm/Client/IdP 初始化脚本
# ============================================
# 功能：确保 Keycloak 中存在 noda-preprod realm 及其配置
# 用途：pre-prod 环境初始化时手动执行
# 前置：KEYCLOAK_ADMIN_USER 和 KEYCLOAK_ADMIN_PASSWORD 环境变量
#       GOOGLE_CLIENT_ID 和 GOOGLE_CLIENT_SECRET 环境变量
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# 环境变量检查
# ============================================
if [[ -z "${KEYCLOAK_ADMIN_USER:-}" ]]; then
    log_error "KEYCLOAK_ADMIN_USER 环境变量未设置"
    log_error "使用方法: export KEYCLOAK_ADMIN_USER='admin'"
    exit 1
fi

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
    log_error "KEYCLOAK_ADMIN_PASSWORD 环境变量未设置"
    log_error "使用方法: export KEYCLOAK_ADMIN_PASSWORD='password'"
    exit 1
fi

if [[ -z "${GOOGLE_CLIENT_ID:-}" ]]; then
    log_error "GOOGLE_CLIENT_ID 环境变量未设置"
    log_error "从 Doppler 加载: source scripts/lib/secrets.sh 或手动 export"
    exit 1
fi

if [[ -z "${GOOGLE_CLIENT_SECRET:-}" ]]; then
    log_error "GOOGLE_CLIENT_SECRET 环境变量未设置"
    log_error "从 Doppler 加载: source scripts/lib/secrets.sh 或手动 export"
    exit 1
fi

# ============================================
# 步骤 1: 检查 Keycloak 容器
# ============================================
log_info "检查 Keycloak 容器状态..."

if ! docker ps --format "{{.Names}}" | grep -q "noda-infra-keycloak-prod"; then
    log_error "Keycloak 容器未运行"
    exit 1
fi

log_success "Keycloak 容器运行正常"

# ============================================
# 步骤 2: 认证到 Keycloak Admin API
# ============================================
log_info "认证到 Keycloak Admin API..."

# 获取 Keycloak 容器名称（处理蓝绿部署）
KEYCLOAK_CONTAINER=$(docker ps --format "{{.Names}}" | grep "keycloak" | head -1)

if [[ -z "$KEYCLOAK_CONTAINER" ]]; then
    log_error "无法找到 Keycloak 容器"
    exit 1
fi

log_info "使用容器: $KEYCLOAK_CONTAINER"

docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080 \
    --realm master \
    --user "$KEYCLOAK_ADMIN_USER" \
    --password "$KEYCLOAK_ADMIN_PASSWORD" \
    >/dev/null 2>&1 || {
    log_error "Keycloak Admin API 认证失败（检查 KEYCLOAK_ADMIN_USER/PASSWORD）"
    exit 1
}

log_success "Keycloak Admin API 认证成功"

# ============================================
# 步骤 3: 创建 noda-preprod realm
# ============================================
log_info "检查并创建 noda-preprod realm..."

REALM_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get realms/noda-preprod 2>/dev/null || echo "")

if [[ -n "$REALM_EXISTS" ]]; then
    log_info "✓ noda-preprod realm 已存在"
else
    log_info "✗ 创建 noda-preprod realm..."

    docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh create realms \
        -s realm=noda-preprod \
        -s enabled=true \
        -s displayName="Noda Pre-Production" \
        -s registrationAllowed=false \
        -s loginTheme=keycloak \
        -s sslRequired=external \
        >/dev/null 2>&1 || {
        log_error "✗ noda-preprod realm 创建失败"
        exit 1
    }

    log_success "✓ noda-preprod realm 已创建"
fi

# ============================================
# 步骤 4: 创建 Google identity provider
# ============================================
log_info "检查并创建 Google identity provider..."

IDP_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
    identity-provider/instances/google \
    -r noda-preprod 2>/dev/null || echo "")

if [[ -n "$IDP_EXISTS" ]]; then
    log_info "✓ Google identity provider 已存在"
else
    log_info "✗ 创建 Google identity provider..."

    docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh create \
        identity-provider/instances \
        -r noda-preprod \
        -s alias=google \
        -s providerId=google \
        -s enabled=true \
        -s "config.clientId=$GOOGLE_CLIENT_ID" \
        -s "config.clientSecret=$GOOGLE_CLIENT_SECRET" \
        -s "config.hostedDomain=noda.co.nz" \
        -s storeToken=true \
        -s trustEmail=false \
        >/dev/null 2>&1 || {
        log_error "✗ Google identity provider 创建失败"
        exit 1
    }

    log_success "✓ Google identity provider 已创建"
fi

# ============================================
# 步骤 5: 创建 noda-frontend-preprod client
# ============================================
log_info "检查并创建 noda-frontend-preprod client..."

# 查找 client 是否存在（通过 clientId 过滤）
CLIENT_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
    clients \
    -r noda-preprod \
    --fields clientId \
    2>/dev/null | grep -c "noda-frontend-preprod" || echo "0")

if [[ "$CLIENT_EXISTS" -ge 1 ]]; then
    log_info "✓ noda-frontend-preprod client 已存在"
else
    log_info "✗ 创建 noda-frontend-preprod client..."

    docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh create clients \
        -r noda-preprod \
        -s clientId=noda-frontend-preprod \
        -s enabled=true \
        -s 'redirectUris=["https://pre.class.noda.co.nz/*","https://pre.auth.noda.co.nz/*"]' \
        -s 'webOrigins=["https://pre.class.noda.co.nz","https://pre.auth.noda.co.nz"]' \
        -s publicClient=true \
        -s 'protocol=openid-connect' \
        -s 'attributes={"access.token.lifespan":"300","pkce.code.challenge.method":"S256"}' \
        >/dev/null 2>&1 || {
        log_error "✗ noda-frontend-preprod client 创建失败"
        exit 1
    }

    log_success "✓ noda-frontend-preprod client 已创建"
fi

# ============================================
# 步骤 6: 验证配置
# ============================================
log_info "验证 noda-preprod realm 配置..."

# 验证 realm 存在
REALM_CHECK=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
    realms/noda-preprod --fields enabled 2>/dev/null | grep -c "true" || echo "0")
if [[ "$REALM_CHECK" -lt 1 ]]; then
    log_error "✗ realm 验证失败"
    exit 1
fi
log_info "✓ realm enabled=true"

# 验证 Google IdP
IDP_CHECK=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
    identity-provider/instances/google \
    -r noda-preprod --fields enabled 2>/dev/null | grep -c "true" || echo "0")
if [[ "$IDP_CHECK" -lt 1 ]]; then
    log_error "✗ Google IdP 验证失败"
    exit 1
fi
log_info "✓ Google IdP enabled=true"

# 验证 client redirect URIs
CLIENT_REDIRECT_CHECK=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
    clients -r noda-preprod --fields clientId,redirectUris 2>/dev/null | grep -c "pre.class.noda.co.nz" || echo "0")
if [[ "$CLIENT_REDIRECT_CHECK" -lt 1 ]]; then
    log_error "✗ client redirect URIs 验证失败"
    exit 1
fi
log_info "✓ client redirect URIs 包含 pre.class.noda.co.nz"

# ============================================
# 步骤 7: 总结
# ============================================
log_success "=========================================="
log_success "Keycloak 初始化完成"
log_success "=========================================="
log_info "Realm: noda-preprod"
log_info "Identity Provider: Google"
log_info "Client: noda-frontend-preprod"
log_info "Redirect URIs:"
log_info "  - https://pre.class.noda.co.nz/*"
log_info "  - https://pre.auth.noda.co.nz/*"
log_success "=========================================="

exit 0
