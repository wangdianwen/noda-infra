#!/bin/bash
# scripts/decrypt-secrets.sh - 解密密钥文件（部署时使用）
# 用法: ./scripts/decrypt-secrets.sh [production|prod|dev|noda] [输出目录] [选项]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/log.sh"

ENV=${1:-production}
DECRYPT_DIR=${2:-/tmp/noda-secrets}
CLEANUP_MODE=false

# 解析参数
shift 2
while [[ $# -gt 0 ]]; do
  case $1 in
    --cleanup)
      CLEANUP_MODE=true
      shift
      ;;
    *)
      log_error "未知参数: $1"
      exit 1
      ;;
  esac
done

# 清理模式：删除所有解密的文件
if [[ "$CLEANUP_MODE" == true ]]; then
  log_info "清理解密的密钥文件..."
  if [[ -d "$DECRYPT_DIR" ]]; then
    find "$DECRYPT_DIR" -name ".env.*" -type f -delete 2>/dev/null || true
    log_success "已清理: $DECRYPT_DIR"
  else
    log_warn "目录不存在: $DECRYPT_DIR"
  fi
  exit 0
fi

# 环境名称映射
case "$ENV" in
  production|prod)
    ENC_FILE="secrets/.env.production.enc"
    OUT_FILE="$DECRYPT_DIR/.env.production"
    VALIDATE_VARS="VERCEL_OIDC_TOKEN VITE_KEYCLOAK_URL"
    ;;
  infra)
    ENC_FILE="secrets/infra.env.prod.enc"
    OUT_FILE="$DECRYPT_DIR/.env.prod"
    VALIDATE_VARS="POSTGRES_PASSWORD POSTGRES_USER"
    ;;
  noda)
    ENC_FILE="secrets/.env.noda.enc"
    OUT_FILE="$DECRYPT_DIR/.env.noda"
    VALIDATE_VARS="KEYCLOAK_ADMIN_USER KEYCLOAK_ADMIN_PASSWORD"
    ;;
  all)
    log_info "解密所有密钥文件到 $DECRYPT_DIR"
    "$0" production "$DECRYPT_DIR"
    "$0" infra "$DECRYPT_DIR"
    "$0" noda "$DECRYPT_DIR"
    exit 0
    ;;
  *)
    echo "用法: $0 [production|infra|noda|all] [输出目录]"
    echo "默认输出目录: /tmp/noda-secrets"
    exit 1
    ;;
esac

log_info "解密 $ENV 环境密钥..."

# 检查依赖
command -v sops >/dev/null 2>&1 || { log_error "SOPS 未安装"; exit 1; }

# 检查加密文件
if [[ ! -f "$ENC_FILE" ]]; then
  log_error "加密文件不存在: $ENC_FILE"
  exit 1
fi

# 创建输出目录
mkdir -p "$DECRYPT_DIR"

# 设置 age 密钥文件环境变量（按优先级检查多个位置）
# 1. 检查 SOPS_AGE_KEY_FILE 环境变量（CI/CD 环境）
if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -f "$SOPS_AGE_KEY_FILE" ]]; then
  log_info "使用密钥文件: $SOPS_AGE_KEY_FILE"
# 2. 检查用户目录中的密钥文件（本地开发）
else
  USER=$(whoami)
  KEY_FILE="team-keys/age-key-${USER}.txt"
  if [[ -f "$KEY_FILE" ]]; then
    export SOPS_AGE_KEY_FILE="$KEY_FILE"
    log_info "使用本地密钥文件: $SOPS_AGE_KEY_FILE"
  else
    log_warn "未找到 age 密钥文件，尝试使用默认 SOPS 配置"
  fi
fi

# 解密到文件（静默模式，不打印内容）
if sops --decrypt "$ENC_FILE" > "$OUT_FILE" 2>/dev/null; then
  chmod 600 "$OUT_FILE"
  log_success "已解密: $OUT_FILE"
else
  log_error "解密失败: $ENC_FILE"
  echo "请确认 age 私钥已正确配置"
  exit 1
fi

# 验证关键变量
for var in $VALIDATE_VARS; do
  if grep -q "^${var}=" "$OUT_FILE"; then
    log_success "验证: $var 存在"
  else
    log_error "缺少关键变量: $var"
    rm -f "$OUT_FILE"
    exit 1
  fi
done

# 注册清理函数（脚本退出时自动删除临时文件）
cleanup() {
  if [[ -f "$OUT_FILE" && "$DECRYPT_DIR" == /tmp/* ]]; then
    rm -f "$OUT_FILE"
    log_info "已清理临时文件: $OUT_FILE"
  fi
}
trap cleanup EXIT

log_success "密钥解密完成: $OUT_FILE"
echo ""
echo "IMPORTANT: 此文件包含敏感信息，使用后请删除"
echo "清理: rm -f $OUT_FILE"
