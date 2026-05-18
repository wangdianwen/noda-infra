#!/bin/bash
# ============================================
# r4s 环境初始化 - 编排入口脚本
# ============================================
# 依次调用所有 setup/verify 脚本，完成 r4s 环境初始化
# 使用方法: bash scripts/r4s/setup-r4s.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

# Source 子脚本（定义函数，不直接执行）
# shellcheck source=scripts/r4s/setup-network.sh
source "${SCRIPT_DIR}/setup-network.sh"
# shellcheck source=scripts/r4s/setup-swap.sh
source "${SCRIPT_DIR}/setup-swap.sh"
# shellcheck source=scripts/r4s/setup-ssh.sh
source "${SCRIPT_DIR}/setup-ssh.sh"
# shellcheck source=scripts/r4s/verify-docker.sh
source "${SCRIPT_DIR}/verify-docker.sh"

main()
{
    log_info "============================================"
    log_info "r4s (iStoreOS) 环境初始化"
    log_info "============================================"
    echo ""

    local step=0
    local total=4

    # Step 1: 创建 Docker 独立网桥
    step=$((step + 1))
    log_info "[${step}/${total}] 创建 Docker 独立网桥..."
    setup_network
    echo ""

    # Step 2: 创建 Swap 文件
    step=$((step + 1))
    log_info "[${step}/${total}] 创建 Swap 文件..."
    setup_swap
    echo ""

    # Step 3: 创建 jenkins 用户 + SSH 配置
    step=$((step + 1))
    log_info "[${step}/${total}] 创建 jenkins 用户 + SSH 配置..."
    setup_jenkins_user
    echo ""

    # Step 4: 验证 Docker 开机自启
    step=$((step + 1))
    log_info "[${step}/${total}] 验证 Docker 开机自启..."
    verify_docker_autostart
    echo ""

    log_info "============================================"
    log_success "r4s 环境初始化完成！"
    log_info "============================================"
}

main
