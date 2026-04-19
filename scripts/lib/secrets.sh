#!/bin/bash
set -euo pipefail

# ============================================
# 密钥加载库（Doppler Only）
# ============================================
# 功能：提供 load_secrets() 函数，从 Doppler API 拉取密钥
# 用途：被 pipeline-stages.sh、blue-green-deploy.sh 等脚本 source 加载
# 模式：DOPPLER_TOKEN 存在 → doppler secrets download 拉取密钥（不落盘）
# 设计决策：per D-03 (Doppler only), D-04 (--no-file 不落盘), D-05 (config=prd)
# ============================================

# ============================================
# 函数: load_secrets
# ============================================
# Doppler-only 密钥加载：
#   - DOPPLER_TOKEN 非空时：从 Doppler API 拉取密钥注入 shell 环境
#   - DOPPLER_TOKEN 为空时：输出错误提示并 return 1
# 返回：0=成功，1=失败
# 环境变量：
#   DOPPLER_TOKEN - Doppler Service Token（必须设置）
load_secrets()
{
    # log 函数 fallback（调用者可能未 source log.sh）
    if ! declare -f log_info >/dev/null 2>&1; then
        log_info()    { echo "[INFO] $*"; }
        log_error()   { echo "[ERROR] $*" >&2; }
        log_success() { echo "[OK] $*"; }
        log_warn()    { echo "[WARN] $*"; }
    fi

    if [ -z "${DOPPLER_TOKEN:-}" ]; then
        log_error "DOPPLER_TOKEN 未设置。请 export DOPPLER_TOKEN=<service-token> 后重试。"
        return 1
    fi

    if ! command -v doppler >/dev/null 2>&1; then
        log_error "DOPPLER_TOKEN 已设置但 doppler CLI 不可用"
        log_error "安装方式: brew install dopplerhq/cli/doppler"
        return 1
    fi

    local _secrets
    _secrets=$(doppler secrets download --no-file --format=env --project noda --config prd 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "Doppler 密钥拉取失败（检查 DOPPLER_TOKEN 是否有效）"
        return 1
    fi

    set -a
    eval "$_secrets"
    set +a

    log_success "密钥已从 Doppler 加载（project=noda, config=prd）"
}
