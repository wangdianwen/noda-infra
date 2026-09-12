#!/bin/bash
set -euo pipefail

# ============================================
# 初始化状态文件目录结构
# ============================================
# 为 prod 和 pre-prod 环境创建独立的状态文件目录

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# 创建状态文件目录
for env in prod preprod; do
    state_dir="/opt/noda/${env}"
    log_info "创建状态目录: ${state_dir}"

    # 使用 sudo 创建目录（生产环境需要）
    if [ -w /opt ]; then
        mkdir -p "${state_dir}"
    else
        sudo mkdir -p "${state_dir}"
        sudo chown $(whoami):$(whoami) "${state_dir}"
    fi
done

log_success "状态文件目录结构创建完成"
