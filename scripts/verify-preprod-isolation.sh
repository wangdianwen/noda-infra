#!/bin/bash
set -euo pipefail

# ============================================
# Pre-prod 环境隔离完整性验证脚本
# ============================================
# 功能：验证 pre-prod 环境的数据库、Keycloak realm、Doppler config 隔离
# 用途：Phase 53 完成后执行，确认三层隔离无泄漏
# 前置：DOPPLER_TOKEN 环境变量（具有 pre config 读取权限）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

FAILURES=0

# ============================================
# 步骤 1: 验证数据库隔离
# ============================================
log_info "=========================================="
log_info "1. 验证数据库隔离"
log_info "=========================================="

# 检查 noda_preprod 数据库存在
DB_EXISTS=$(docker exec noda-infra-postgres-prod psql -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='noda_preprod';" 2>/dev/null || echo "0")

if [[ "$DB_EXISTS" == "1" ]]; then
    log_success "✓ noda_preprod 数据库存在"
else
    log_error "✗ noda_preprod 数据库不存在"
    ((FAILURES++))
fi

# 检查 noda_prod 数据库存在（确保 prod 未被影响）
PROD_DB_EXISTS=$(docker exec noda-infra-postgres-prod psql -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname='noda_prod';" 2>/dev/null || echo "0")

if [[ "$PROD_DB_EXISTS" == "1" ]]; then
    log_success "✓ noda_prod 数据库未受影响"
else
    log_error "✗ noda_prod 数据库不存在（prod 被破坏！）"
    ((FAILURES++))
fi

# 检查 preprod_app 用户存在
USER_EXISTS=$(docker exec noda-infra-postgres-prod psql -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='preprod_app';" 2>/dev/null || echo "0")

if [[ "$USER_EXISTS" == "1" ]]; then
    log_success "✓ preprod_app 用户存在"
else
    log_warn "⚠ preprod_app 用户不存在（可选，使用 postgres 超级用户）"
fi

# ============================================
# 步骤 2: 验证 Keycloak realm 隔离
# ============================================
log_info "=========================================="
log_info "2. 验证 Keycloak realm 隔离"
log_info "=========================================="

KEYCLOAK_CONTAINER=$(docker ps --format "{{.Names}}" | grep "keycloak" | head -1)

if [[ -z "$KEYCLOAK_CONTAINER" ]]; then
    log_error "✗ Keycloak 容器未运行"
    ((FAILURES++))
else
    # 检查 noda-preprod realm 存在
    REALM_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get realms/noda-preprod --fields realm 2>/dev/null | grep -c "noda-preprod" || echo "0")

    if [[ "$REALM_EXISTS" -ge 1 ]]; then
        log_success "✓ noda-preprod realm 存在"
    else
        log_error "✗ noda-preprod realm 不存在"
        ((FAILURES++))
    fi

    # 检查 noda realm 存在（确保 prod 未被影响）
    PROD_REALM_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get realms/noda --fields realm 2>/dev/null | grep -c "noda" || echo "0")

    if [[ "$PROD_REALM_EXISTS" -ge 1 ]]; then
        log_success "✓ noda (prod) realm 未受影响"
    else
        log_error "✗ noda (prod) realm 不存在（prod 被破坏！）"
        ((FAILURES++))
    fi

    # 检查 Google IdP
    IDP_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
        identity-provider/instances/google -r noda-preprod --fields alias 2>/dev/null | grep -c "google" || echo "0")

    if [[ "$IDP_EXISTS" -ge 1 ]]; then
        log_success "✓ Google identity provider 已配置"
    else
        log_error "✗ Google identity provider 未配置"
        ((FAILURES++))
    fi

    # 检查 client
    CLIENT_EXISTS=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
        clients -r noda-preprod --fields clientId 2>/dev/null | grep -c "noda-frontend-preprod" || echo "0")

    if [[ "$CLIENT_EXISTS" -ge 1 ]]; then
        log_success "✓ noda-frontend-preprod client 存在"
    else
        log_error "✗ noda-frontend-preprod client 不存在"
        ((FAILURES++))
    fi

    # 检查 redirect URIs
    REDIRECT_CHECK=$(docker exec "$KEYCLOAK_CONTAINER" /opt/keycloak/bin/kcadm.sh get \
        clients -r noda-preprod --fields redirectUris 2>/dev/null | grep -c "pre.class.noda.co.nz" || echo "0")

    if [[ "$REDIRECT_CHECK" -ge 1 ]]; then
        log_success "✓ redirect URIs 包含 pre.class.noda.co.nz"
    else
        log_error "✗ redirect URIs 不包含 pre.class.noda.co.nz"
        ((FAILURES++))
    fi
fi

# ============================================
# 步骤 3: 验证 Doppler config 隔离
# ============================================
log_info "=========================================="
log_info "3. 验证 Doppler config 隔离"
log_info "=========================================="

if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
    log_warn "⚠ DOPPLER_TOKEN 未设置，跳过 Doppler 验证"
    log_warn "  使用方法: DOPPLER_TOKEN='dp.st.pre.xxx' bash scripts/verify-preprod-isolation.sh"
else
    if ! command -v doppler &>/dev/null; then
        log_error "✗ doppler CLI 未安装"
        ((FAILURES++))
    else
        # 检查 pre config 可访问
        if doppler secrets --only-names --project noda --config pre >/dev/null 2>&1; then
            log_success "✓ Doppler pre config 可访问"
        else
            log_error "✗ Doppler pre config 不可访问"
            ((FAILURES++))
        fi

        # 检查 POSTGRES_DB
        PREPROD_DB=$(doppler secrets get POSTGRES_DB --plain --project noda --config pre 2>/dev/null || echo "")
        if [[ "$PREPROD_DB" == "noda_preprod" ]]; then
            log_success "✓ POSTGRES_DB = noda_preprod"
        else
            log_error "✗ POSTGRES_DB = '$PREPROD_DB'（预期: noda_preprod）"
            ((FAILURES++))
        fi

        # 检查 KEYCLOAK_REALM
        PREPROD_REALM=$(doppler secrets get KEYCLOAK_REALM --plain --project noda --config pre 2>/dev/null || echo "")
        if [[ "$PREPROD_REALM" == "noda-preprod" ]]; then
            log_success "✓ KEYCLOAK_REALM = noda-preprod"
        else
            log_error "✗ KEYCLOAK_REALM = '$PREPROD_REALM'（预期: noda-preprod）"
            ((FAILURES++))
        fi

        # 确认 prd config 未被修改（安全检查）
        PROD_DB=$(doppler secrets get POSTGRES_DB --plain --project noda --config prd 2>/dev/null || echo "")
        if [[ "$PROD_DB" == "noda_prod" ]]; then
            log_success "✓ prd config POSTGRES_DB 未被修改（仍为 noda_prod）"
        else
            log_error "✗ prd config POSTGRES_DB 已被修改为 '$PROD_DB'（prod 被污染！）"
            ((FAILURES++))
        fi
    fi
fi

# ============================================
# 总结
# ============================================
log_info "=========================================="
if [[ $FAILURES -eq 0 ]]; then
    log_success "Pre-prod 环境隔离验证通过"
    log_success "所有检查项均正常"
else
    log_error "Pre-prod 环境隔离验证失败"
    log_error "$FAILURES 项检查未通过"
fi
log_info "=========================================="

exit $FAILURES
