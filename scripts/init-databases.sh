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
  IFS=':' read -r db_name db_desc <<< "$db_info"

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
      > /dev/null 2>&1; then
      log_success "✓ $db_name 已创建"
      ((CREATED_COUNT++))
    else
      log_error "✗ $db_name 创建失败"
      exit 1
    fi
  fi
done

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
