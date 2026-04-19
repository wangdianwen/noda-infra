#!/bin/bash
set -euo pipefail

# ============================================
# 密钥加载库（Doppler 双模式）
# ============================================
# 功能：提供 load_secrets() 函数，支持 Doppler API 和本地 .env 两种密钥加载方式
# 用途：被 pipeline-stages.sh、blue-green-deploy.sh 等脚本 source 加载
# 模式：
#   1. DOPPLER_TOKEN 存在 → doppler secrets download 拉取密钥（不落盘）
#   2. DOPPLER_TOKEN 不存在 → 回退到 source docker/.env
# 设计决策：per D-03 (Doppler 优先), D-04 (--no-file 不落盘), D-05 (config=prd), D-10 (回退 .env)
# ============================================

# ============================================
# 函数: load_secrets
# ============================================
# 双模式密钥加载：
#   - DOPPLER_TOKEN 非空时：从 Doppler API 拉取密钥注入 shell 环境
#   - DOPPLER_TOKEN 为空时：回退到 source docker/.env 文件
# 返回：0=成功，1=失败
# 环境变量：
#   DOPPLER_TOKEN - Doppler Service Token（设置后启用 Doppler 模式）
#   PROJECT_ROOT  - 项目根目录（回退模式下用于定位 docker/.env）
load_secrets()
{
    # log 函数 fallback（调用者可能未 source log.sh）
    if ! declare -f log_info >/dev/null 2>&1; then
        log_info()    { echo "[INFO] $*"; }
        log_error()   { echo "[ERROR] $*" >&2; }
        log_success() { echo "[OK] $*"; }
        log_warn()    { echo "[WARN] $*"; }
    fi

    if [ -n "${DOPPLER_TOKEN:-}" ]; then
        # === Doppler 模式 ===
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
    else
        # === .env 回退模式 ===
        local _loaded=false
        for _env_path in "${PROJECT_ROOT:-.}/docker/.env" "$HOME/Project/noda-infra/docker/.env"; do
            if [ -f "$_env_path" ]; then
                set -a
                # shellcheck source=/dev/null
                source "$_env_path"
                set +a
                log_info "密钥已从本地文件加载: $_env_path"
                _loaded=true
                break
            fi
        done

        if [ "$_loaded" = "false" ]; then
            log_error "未找到密钥文件（DOPPLER_TOKEN 未设置，且 docker/.env 不存在）"
            log_error "请设置 DOPPLER_TOKEN 或确保 docker/.env 文件存在"
            return 1
        fi
    fi
}
