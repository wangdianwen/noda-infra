#!/bin/bash
# ============================================
# r4s 环境初始化 - Swap 文件配置
# ============================================
# 幂等创建 2GB Swap 文件 + UCI fstab 持久化 + swappiness 调优
# 使用方法: bash scripts/r4s/setup-swap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

# 常量（D-21: Swap 文件放在 SD 卡 Docker 数据目录）
SWAPFILE="/mnt/mmc1-4/docker/swapfile"
SWAP_SIZE_MB=2048

setup_swap()
{
    local swap_dir
    swap_dir="$(dirname "${SWAPFILE}")"

    # 幂等检查：Swap 已启用则跳过
    if swapon --show | grep -q "${SWAPFILE}"; then
        log_success "Swap 文件 ${SWAPFILE} 已启用，跳过创建"
        return 0
    fi

    # 检查 Docker 数据目录存在性
    if [[ ! -d "${swap_dir}" ]]; then
        log_error "Docker 数据目录 ${swap_dir} 不存在，请先确认 Docker 安装"
        return 1
    fi

    # 检查磁盘空间
    local available_kb
    available_kb="$(df "${swap_dir}" | awk 'NR==2{print $4}')"
    local required_kb=$((SWAP_SIZE_MB * 1024))
    if [[ "${available_kb}" -lt "${required_kb}" ]]; then
        log_error "磁盘空间不足: 需要 ${SWAP_SIZE_MB}MB，可用 $((available_kb / 1024))MB"
        return 1
    fi

    # 创建 Swap 文件（D-21: 使用 dd 而非 fallocate，兼容所有文件系统）
    log_info "创建 ${SWAP_SIZE_MB}MB Swap 文件 ${SWAPFILE}..."
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count="${SWAP_SIZE_MB}" status=progress

    # 设置权限
    chmod 600 "${SWAPFILE}"

    # 格式化并启用
    mkswap "${SWAPFILE}"
    swapon "${SWAPFILE}"

    log_success "Swap 文件创建并启用成功"
    free -m | grep -i swap

    # 持久化 Swap 配置
    persist_swap

    # 调优 swappiness
    configure_swappiness
}

persist_swap()
{
    # 幂等检查：UCI fstab 已配置则跳过（iStoreOS/OpenWrt 使用 UCI 管理 fstab）
    if uci get fstab.@swap[-1].device 2>/dev/null | grep -q "${SWAPFILE}"; then
        log_success "UCI fstab Swap 配置已存在，跳过"
        return 0
    fi

    log_info "配置 UCI fstab 持久化..."
    uci add fstab swap
    uci set fstab.@swap[-1].device="${SWAPFILE}"
    uci set fstab.@swap[-1].enabled='1'
    uci commit fstab

    log_success "UCI fstab Swap 配置完成"
}

configure_swappiness()
{
    local target_swappiness=10  # D-22: swappiness=10，内核尽量用 RAM

    # 幂等检查
    local current
    current="$(cat /proc/sys/vm/swappiness)"
    if [[ "${current}" -eq "${target_swappiness}" ]]; then
        log_success "vm.swappiness 已为 ${target_swappiness}，跳过"
        return 0
    fi

    log_info "设置 vm.swappiness=${target_swappiness}..."
    sysctl -w vm.swappiness="${target_swappiness}"

    # 持久化到 /etc/sysctl.conf
    if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sed -i "s/^vm.swappiness=.*/vm.swappiness=${target_swappiness}/" /etc/sysctl.conf
    else
        echo "vm.swappiness=${target_swappiness}" >>/etc/sysctl.conf
    fi

    log_success "vm.swappiness 持久化完成"
}

# 支持独立运行和 source 引入
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_swap
fi
