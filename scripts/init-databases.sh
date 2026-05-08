#!/bin/bash
set -euo pipefail

# ============================================
# 数据库初始化脚本
# ============================================
# 功能：确保所有必要的数据库存在
# 用途：容器启动时自动执行，防止数据库缺失
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# 必要的数据库列表
# ============================================
REQUIRED_DBS=(
    "noda_prod:Findclass Application Database"
    "noda_preprod:Findclass Application Database (pre-prod)"
    "keycloak:Keycloak Authentication Database"
)

# ============================================
# 步骤 1: 检查 PostgreSQL 容器
# ============================================
log_info "检查 PostgreSQL 容器状态..."

if ! docker ps --format "{{.Names}}" | grep -q "noda-infra-postgres-prod"; then
    log_error "PostgreSQL 容器未运行"
    exit 1
fi

log_success "PostgreSQL 容器运行正常"

# ============================================
# 步骤 2: 确保所有数据库存在
# ============================================
log_info "检查并创建必要的数据库..."

CREATED_COUNT=0
SKIPPED_COUNT=0

for db_info in "${REQUIRED_DBS[@]}"; do
    IFS=':' read -r db_name db_desc <<<"$db_info"

    # 检查数据库是否存在
    DB_EXISTS=$(docker exec noda-infra-postgres-prod psql -U postgres -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$db_name';" 2>/dev/null || echo "0")

    if [ "$DB_EXISTS" = "1" ]; then
        log_info "✓ $db_name ($db_desc)"
        ((SKIPPED_COUNT++))
    else
        log_info "✗ 创建 $db_name ($db_desc)..."

        # 创建数据库
        if docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c \
            "CREATE DATABASE $db_name WITH OWNER = postgres ENCODING = 'UTF8' LC_COLLATE = 'en_US.utf8' LC_CTYPE = 'en_US.utf8' TEMPLATE = template0 CONNECTION LIMIT = -1;" \
            >/dev/null 2>&1; then
            log_success "✓ $db_name 已创建"
            ((CREATED_COUNT++))
        else
            log_error "✗ $db_name 创建失败"
            exit 1
        fi
    fi
done

# ============================================
# 步骤 2.5: 创建 pre-prod 独立用户（如果需要）
# ============================================
PREPROD_USER="preprod_app"
PREPROD_PASSWORD="${PREPROD_APP_PASSWORD:-$(openssl rand -hex 16)}"

# 检查 preprod_app 用户是否已存在
USER_EXISTS=$(docker exec noda-infra-postgres-prod psql -U postgres -d postgres -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$PREPROD_USER';" 2>/dev/null || echo "0")

if [ "$USER_EXISTS" = "1" ]; then
    log_info "✓ $PREPROD_USER 用户已存在"
else
    log_info "✗ 创建 $PREPROD_USER 用户..."
    if docker exec noda-infra-postgres-prod psql -U postgres -d postgres -c \
        "CREATE USER $PREPROD_USER WITH ENCRYPTED PASSWORD '$PREPROD_PASSWORD';" \
        >/dev/null 2>&1; then
        log_success "✓ $PREPROD_USER 用户已创建"
    else
        log_error "✗ $PREPROD_USER 用户创建失败"
        exit 1
    fi
fi

# 授予 noda_preprod 数据库权限给 preprod_app 用户
log_info "配置 $PREPROD_USER 对 noda_preprod 的权限..."
docker exec noda-infra-postgres-prod psql -U postgres -d noda_preprod -c \
    "GRANT ALL PRIVILEGES ON DATABASE noda_preprod TO $PREPROD_USER;" >/dev/null 2>&1 || true
docker exec noda-infra-postgres-prod psql -U postgres -d noda_preprod -c \
    "GRANT ALL ON SCHEMA public TO $PREPROD_USER;" >/dev/null 2>&1 || true
docker exec noda-infra-postgres-prod psql -U postgres -d noda_preprod -c \
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $PREPROD_USER;" >/dev/null 2>&1 || true
docker exec noda-infra-postgres-prod psql -U postgres -d noda_preprod -c \
    "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $PREPROD_USER;" >/dev/null 2>&1 || true
log_success "✓ $PREPROD_USER 权限配置完成"

# ============================================
# 步骤 3: 总结
# ============================================
log_success "=========================================="
log_success "数据库初始化完成"
log_success "=========================================="
log_info "创建: $CREATED_COUNT 个新数据库"
log_info "已存在: $SKIPPED_COUNT 个数据库"
log_success "=========================================="

exit 0
