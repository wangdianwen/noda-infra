#!/usr/bin/env bash
# Doppler 密钥完整性验证脚本
# 用途：验证 Doppler 项目 "noda" 环境 "prd" 中所有预期密钥是否完整
# 使用：DOPPLER_TOKEN='dp.st.prd.xxx' bash scripts/verify-doppler-secrets.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检查 DOPPLER_TOKEN
if [[ -z "${DOPPLER_TOKEN:-}" ]]; then
    error "DOPPLER_TOKEN 环境变量未设置"
    error "使用方法: export DOPPLER_TOKEN='dp.st.prd.xxx'"
    exit 1
fi

# 检查 doppler CLI
if ! command -v doppler &>/dev/null; then
    error "doppler CLI 未安装，请先运行: bash scripts/install-doppler.sh"
    exit 1
fi

# 项目和环境配置
PROJECT="${1:-noda}"
CONFIG="${2:-prd}"

# 预期密钥列表（17 个，排除 VITE_* 和备份系统密钥）
EXPECTED_SECRETS=(
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "POSTGRES_DB"
    "KEYCLOAK_ADMIN_USER"
    "KEYCLOAK_ADMIN_PASSWORD"
    "KEYCLOAK_DB_PASSWORD"
    "CLOUDFLARE_TUNNEL_TOKEN"
    "ANTHROPIC_AUTH_TOKEN"
    "ANTHROPIC_BASE_URL"
    "SMTP_HOST"
    "SMTP_PORT"
    "SMTP_FROM"
    "SMTP_USER"
    "SMTP_PASSWORD"
    "RESEND_API_KEY"
    "GOOGLE_CLIENT_ID"
    "GOOGLE_CLIENT_SECRET"
)

info "验证 Doppler 项目 '${PROJECT}' 环境 '${CONFIG}' 的密钥完整性..."
info "预期密钥数量: ${#EXPECTED_SECRETS[@]}"

# 获取远程密钥列表
REMOTE_SECRETS=$(doppler secrets --only-names --project "$PROJECT" --config "$CONFIG" 2>/dev/null) || {
    error "无法获取 Doppler 密钥列表，请检查 DOPPLER_TOKEN 和项目配置"
    exit 1
}

# 逐个验证
MISSING=()
FOUND=0

for secret in "${EXPECTED_SECRETS[@]}"; do
    if echo "$REMOTE_SECRETS" | grep -q "$secret"; then
        FOUND=$((FOUND + 1))
        echo -e "  ${GREEN}✓${NC} $secret"
    else
        MISSING+=("$secret")
        echo -e "  ${RED}✗${NC} $secret"
    fi
done

# 输出结果
echo ""
TOTAL=${#EXPECTED_SECRETS[@]}

if [[ ${#MISSING[@]} -eq 0 ]]; then
    info "验证通过: ${FOUND}/${TOTAL} 密钥完整"
    exit 0
else
    error "验证失败: ${FOUND}/${TOTAL} 密钥完整，缺少 ${#MISSING[@]} 个"
    echo ""
    echo "缺少的密钥:"
    for m in "${MISSING[@]}"; do
        echo -e "  ${RED}- $m${NC}"
    done
    exit 1
fi
