#!/bin/bash
# ============================================
# r4s 环境初始化 - Docker 独立网桥创建
# ============================================
# 幂等创建 noda-network 独立网桥
# 使用方法: bash scripts/r4s/setup-network.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

setup_network()
{
    local network_name="noda-network"

    # 幂等检查：网桥已存在则跳过
    if docker network ls --format '{{.Name}}' | grep -q "^${network_name}$"; then
        log_success "Docker 网桥 ${network_name} 已存在，跳过创建"
        docker network inspect "${network_name}" --format '{{range .IPAM.Config}}子网: {{.Subnet}}{{end}}'
        return 0
    fi

    # 创建网桥（D-29: 使用默认子网 172.17.x.x，与 iStoreOS LAN 192.168.x.x 不冲突）
    log_info "创建 Docker 独立网桥 ${network_name}..."
    docker network create \
        --driver bridge \
        --label noda.managed=true \
        "${network_name}"

    # 显示网桥信息
    log_success "Docker 网桥 ${network_name} 创建成功"
    docker network inspect "${network_name}" --format '{{range .IPAM.Config}}子网: {{.Subnet}}{{end}}'
}

# 支持独立运行和 source 引入
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_network
fi
