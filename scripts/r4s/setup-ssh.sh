#!/bin/bash
# ============================================
# r4s 环境初始化 - SSH 用户配置
# ============================================
# 幂等创建 jenkins 用户 + SSH 免密登录配置
# 使用方法: bash scripts/r4s/setup-ssh.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

# 常量（D-24: 专用 jenkins 用户，D-25: ed25519 密钥类型）
JENKINS_USER="jenkins"
JENKINS_HOME="/home/jenkins"
JENKINS_SSH_DIR="${JENKINS_HOME}/.ssh"

setup_jenkins_user()
{
    # 检查并安装 shadow-useradd/usermod（iStoreOS 默认无 useradd 命令）
    if ! command -v useradd >/dev/null 2>&1; then
        log_info "安装 shadow-useradd / shadow-usermod..."
        opkg update
        opkg install shadow-useradd shadow-usermod
    fi

    # 幂等检查：用户已存在则跳过创建
    if id "${JENKINS_USER}" >/dev/null 2>&1; then
        log_success "用户 ${JENKINS_USER} 已存在，跳过创建"
    else
        log_info "创建用户 ${JENKINS_USER}..."
        # Pitfall 5: iStoreOS 默认 shell 是 /bin/ash，不是 /bin/bash
        useradd -m -s /bin/ash "${JENKINS_USER}"
        log_success "用户 ${JENKINS_USER} 创建成功"
    fi

    # 确保 docker 组存在
    ensure_docker_group

    # 将 jenkins 加入 docker 组（D-24: 仅 docker 组，不配置 sudo）
    if id -nG "${JENKINS_USER}" | grep -qw docker; then
        log_success "${JENKINS_USER} 已在 docker 组中，跳过"
    else
        usermod -aG docker "${JENKINS_USER}"
        log_success "${JENKINS_USER} 已加入 docker 组"
    fi

    # 创建 .ssh 目录和 authorized_keys 文件
    setup_ssh_dir
}

ensure_docker_group()
{
    if grep -q "^docker:" /etc/group; then
        return 0
    fi
    log_info "创建 docker 组..."
    groupadd docker 2>/dev/null || addgroup docker 2>/dev/null || true
    log_success "docker 组已创建"
}

setup_ssh_dir()
{
    # 创建 .ssh 目录
    mkdir -p "${JENKINS_SSH_DIR}"
    chmod 700 "${JENKINS_SSH_DIR}"

    # 创建空的 authorized_keys（D-27: 仅添加 Jenkins 公钥）
    local auth_keys="${JENKINS_SSH_DIR}/authorized_keys"
    if [[ ! -f "${auth_keys}" ]]; then
        touch "${auth_keys}"
    fi
    chmod 600 "${auth_keys}"

    # 设置 owner
    chown -R "${JENKINS_USER}:${JENKINS_USER}" "${JENKINS_SSH_DIR}"

    log_success "SSH 目录配置完成: ${JENKINS_SSH_DIR}"
}

# 辅助函数：添加公钥到 authorized_keys（幂等）
# 用法: add_authorized_key "ssh-ed25519 AAAA... jenkins@mac"
add_authorized_key()
{
    local pubkey="$1"
    local auth_keys="${JENKINS_SSH_DIR}/authorized_keys"

    if [[ ! -f "${auth_keys}" ]]; then
        log_error "authorized_keys 文件不存在，请先运行 setup_jenkins_user"
        return 1
    fi

    # 幂等检查：公钥已存在则跳过
    if grep -qF "${pubkey}" "${auth_keys}"; then
        log_success "公钥已存在，跳过添加"
        return 0
    fi

    echo "${pubkey}" >>"${auth_keys}"
    log_success "公钥已添加到 authorized_keys"
}

# 支持独立运行和 source 引入
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_jenkins_user
fi
