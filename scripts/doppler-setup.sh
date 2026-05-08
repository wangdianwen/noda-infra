#!/bin/bash
set -euo pipefail

# ============================================
# Doppler Pre-prod Config 初始化脚本
# ============================================
# 功能：创建 Doppler pre config 并配置 pre-prod 密钥
# 用途：pre-prod 环境初始化时手动执行
# 前置：DOPPLER_TOKEN 环境变量（必须为 CLI Token，以 dp.ct. 开头）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

PROJECT="noda"
SOURCE_CONFIG="prd"
TARGET_CONFIG="pre"

# ============================================
# 环境变量检查
# ============================================
if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
    log_error "DOPPLER_TOKEN 环境变量未设置"
    log_error "使用方法: export DOPPLER_TOKEN='<cli-token>'"
    exit 1
fi

# 验证 Token 类型：doppler-setup.sh 需要创建 config 和 token，必须使用 CLI Token
if [[ ! "$DOPPLER_TOKEN" =~ ^dp\.ct\. ]]; then
    log_error "DOPPLER_TOKEN 类型不正确"
    log_error "当前 token 以 '$(echo "$DOPPLER_TOKEN" | cut -c1-6)...' 开头"
    log_error "doppler-setup.sh 需要创建 config 和 service token，必须使用 CLI Token（dp.ct.*）"
    log_error "Service Token（dp.st.*）仅有只读权限，无法创建 config"
    log_error "获取 CLI Token: Doppler Dashboard -> Settings -> CLI -> Generate Token"
    exit 1
fi

if ! command -v doppler &>/dev/null; then
    log_error "doppler CLI 未安装"
    log_error "安装方式: brew install dopplerhq/cli/doppler"
    exit 1
fi

# ============================================
# 步骤 1: 检查 pre config 是否已存在
# ============================================
log_info "检查 Doppler $TARGET_CONFIG config..."

CONFIG_EXISTS=$(doppler configs list --project "$PROJECT" --json 2>/dev/null | grep -c "\"name\": \"$TARGET_CONFIG\"" || echo "0")

if [[ "$CONFIG_EXISTS" -ge 1 ]]; then
    log_info "✓ $TARGET_CONFIG config 已存在"
else
    log_info "✗ 从 $SOURCE_CONFIG config 克隆创建 $TARGET_CONFIG config..."

    # 克隆 prd config 到 pre config
    doppler configs clone "$SOURCE_CONFIG" "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1 || {
        log_error "✗ $TARGET_CONFIG config 克隆失败"
        log_error "尝试手动创建..."
        doppler configs create "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1 || {
            log_error "✗ 手动创建也失败，请检查 Doppler Token 权限"
            exit 1
        }
        # 手动创建后需要上传密钥
        log_info "从 $SOURCE_CONFIG 下载密钥..."
        doppler secrets download --format=env --project "$PROJECT" --config "$SOURCE_CONFIG" 2>/dev/null | \
            doppler secrets upload - --project "$PROJECT" --config "$TARGET_CONFIG" >/dev/null 2>&1 || {
            log_error "✗ 密钥上传失败"
            exit 1
        }
    }

    log_success "✓ $TARGET_CONFIG config 已创建"
fi

# ============================================
# 步骤 2: 修改 pre config 中的关键密钥
# ============================================
log_info "配置 pre-prod 特定密钥..."

# 修改 POSTGRES_DB
doppler secrets set POSTGRES_DB "noda_preprod" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
log_info "✓ POSTGRES_DB = noda_preprod"

# 修改 KEYCLOAK_REALM
doppler secrets set KEYCLOAK_REALM "noda-preprod" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
log_info "✓ KEYCLOAK_REALM = noda-preprod"

# 修改 KEYCLOAK_CLIENT_ID（如果存在于 config 中）
if doppler secrets get KEYCLOAK_CLIENT_ID --plain --config "$SOURCE_CONFIG" --project "$PROJECT" >/dev/null 2>&1; then
    doppler secrets set KEYCLOAK_CLIENT_ID "noda-frontend-preprod" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
    log_info "✓ KEYCLOAK_CLIENT_ID = noda-frontend-preprod"
fi

# 修改 KEYCLOAK_URL（如果存在于 config 中）
if doppler secrets get KEYCLOAK_URL --plain --config "$SOURCE_CONFIG" --project "$PROJECT" >/dev/null 2>&1; then
    doppler secrets set KEYCLOAK_URL "https://pre.auth.noda.co.nz" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
    log_info "✓ KEYCLOAK_URL = https://pre.auth.noda.co.nz"
fi

# 注意：DATABASE_URL 和 DIRECT_URL 需要指向 noda_preprod
# 这些 URL 包含用户名密码，需要从现有 URL 中替换数据库名
# DATABASE_URL 转换链路:
#   doppler secrets get DATABASE_URL --plain
#     -> 获取当前 URL（如 postgresql://user:pass@host:5432/noda_prod 或 postgresql://user:pass@host:5432/noda_prod?sslmode=require）
#     -> sed 三模式替换处理:
#        1) /noda_prod$ — URL 以数据库名结尾（无 query params）
#        2) /noda_prod? — URL 后有 query params（如 ?sslmode=require）
#        3) /noda_prod  — URL 末尾有换行/空格（行尾空格模式，第三个 sed 清理尾部空格）
#     -> doppler secrets set DATABASE_URL <new_url>
# 覆盖格式: 标准 PostgreSQL URL (postgresql://...) 和带 query params 的 URL
CURRENT_DB_URL=$(doppler secrets get DATABASE_URL --plain --config "$TARGET_CONFIG" --project "$PROJECT" 2>/dev/null || echo "")
if [[ -n "$CURRENT_DB_URL" ]]; then
    # 替换 URL 中的数据库名
    # 模式 1: /noda_prod 在 URL 末尾（最常见：无 query params）
    # 模式 2: /noda_prod 后跟 ?（有 query params 如 ?sslmode=require）
    # 模式 3: /noda_prod 后跟空格或换行（边界情况清理）
    NEW_DB_URL=$(echo "$CURRENT_DB_URL" | sed 's|/noda_prod$|/noda_preprod|' | sed 's|/noda_prod?|/noda_preprod?|' | sed 's|/noda_prod |/noda_preprod |')
    if [[ "$NEW_DB_URL" != "$CURRENT_DB_URL" ]]; then
        doppler secrets set DATABASE_URL "$NEW_DB_URL" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
        log_info "✓ DATABASE_URL 指向 noda_preprod"
    else
        log_warn "⚠ DATABASE_URL 未能替换（当前值可能不含 /noda_prod 路径段）"
        log_warn "  当前值: $CURRENT_DB_URL"
    fi
fi

CURRENT_DIRECT_URL=$(doppler secrets get DIRECT_URL --plain --config "$TARGET_CONFIG" --project "$PROJECT" 2>/dev/null || echo "")
if [[ -n "$CURRENT_DIRECT_URL" ]]; then
    NEW_DIRECT_URL=$(echo "$CURRENT_DIRECT_URL" | sed 's|/noda_prod$|/noda_preprod|' | sed 's|/noda_prod?|/noda_preprod?|' | sed 's|/noda_prod |/noda_preprod |')
    if [[ "$NEW_DIRECT_URL" != "$CURRENT_DIRECT_URL" ]]; then
        doppler secrets set DIRECT_URL "$NEW_DIRECT_URL" --config "$TARGET_CONFIG" --project "$PROJECT" >/dev/null 2>&1
        log_info "✓ DIRECT_URL 指向 noda_preprod"
    else
        log_warn "⚠ DIRECT_URL 未能替换（当前值可能不含 /noda_prod 路径段）"
    fi
fi

# ============================================
# 步骤 3: 创建 Service Token（用于 Pipeline）
# ============================================
log_info "创建 pre config Service Token..."

# 检查 token 是否已存在
EXISTING_TOKENS=$(doppler configs tokens list --config "$TARGET_CONFIG" --project "$PROJECT" --json 2>/dev/null || echo "[]")
TOKEN_NAME="pre-prod-jenkins"

if echo "$EXISTING_TOKENS" | grep -q "$TOKEN_NAME" 2>/dev/null; then
    log_info "✓ Service Token '$TOKEN_NAME' 已存在"
else
    TOKEN_OUTPUT=$(doppler configs tokens create "$TOKEN_NAME" \
        --config "$TARGET_CONFIG" \
        --project "$PROJECT" \
        --plain \
        --max-age 0 2>/dev/null || echo "")

    if [[ -n "$TOKEN_OUTPUT" && "$TOKEN_OUTPUT" == dp.st.* ]]; then
        log_success "✓ Service Token 已创建"
        log_warn "=========================================="
        log_warn "请保存以下 Service Token 到安全位置："
        log_warn "$TOKEN_OUTPUT"
        log_warn "后续需配置到 Jenkins Credentials"
        log_warn "=========================================="
    else
        log_warn "⚠ Service Token 创建失败或输出格式异常"
        log_warn "可手动创建: doppler configs tokens create $TOKEN_NAME --config $TARGET_CONFIG --project $PROJECT --plain"
    fi
fi

# ============================================
# 步骤 4: 验证 pre config
# ============================================
log_info "验证 $TARGET_CONFIG config 密钥..."

PREPROD_DB=$(doppler secrets get POSTGRES_DB --plain --config "$TARGET_CONFIG" --project "$PROJECT" 2>/dev/null || echo "")
if [[ "$PREPROD_DB" == "noda_preprod" ]]; then
    log_info "✓ POSTGRES_DB = $PREPROD_DB"
else
    log_error "✗ POSTGRES_DB 配置错误: '$PREPROD_DB'（预期: noda_preprod）"
    exit 1
fi

PREPROD_REALM=$(doppler secrets get KEYCLOAK_REALM --plain --config "$TARGET_CONFIG" --project "$PROJECT" 2>/dev/null || echo "")
if [[ "$PREPROD_REALM" == "noda-preprod" ]]; then
    log_info "✓ KEYCLOAK_REALM = $PREPROD_REALM"
else
    log_error "✗ KEYCLOAK_REALM 配置错误: '$PREPROD_REALM'（预期: noda-preprod）"
    exit 1
fi

# ============================================
# 步骤 5: 总结
# ============================================
log_success "=========================================="
log_success "Doppler pre config 初始化完成"
log_success "=========================================="
log_info "Config: $TARGET_CONFIG"
log_info "POSTGRES_DB: noda_preprod"
log_info "KEYCLOAK_REALM: noda-preprod"
log_info "KEYCLOAK_CLIENT_ID: noda-frontend-preprod"
log_success "=========================================="

exit 0
