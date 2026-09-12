#!/bin/bash
# ============================================
# r4s 环境初始化 - Docker 开机自启验证
# ============================================
# 验证 Docker 开机自启 + 容器 restart 策略 + 系统资源概况
# 使用方法: bash scripts/r4s/verify-docker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/../lib/log.sh"

verify_docker_autostart()
{
    log_info "=== Docker 开机自启验证 ==="

    # 检查 dockerd init 脚本（D-31: iStoreOS 使用 /etc/init.d/dockerd）
    if [[ ! -x /etc/init.d/dockerd ]]; then
        log_error "/etc/init.d/dockerd 不存在或不可执行"
        return 1
    fi

    # 检查是否已启用开机自启
    if /etc/init.d/dockerd enabled; then
        log_success "Docker 开机自启已启用"
    else
        log_warn "Docker 开机自启未启用，正在启用..."
        /etc/init.d/dockerd enable
        log_success "Docker 开机自启已启用"
    fi

    # 检查 Docker 运行状态
    if docker info >/dev/null 2>&1; then
        local docker_version
        docker_version="$(docker version --format '{{.Server.Version}}')"
        log_success "Docker 运行中 (版本: ${docker_version})"
    else
        log_error "Docker 未运行，请执行: /etc/init.d/dockerd start"
        return 1
    fi

    # 检查容器 restart 策略（ENV-05: 所有容器应为 unless-stopped）
    log_info "检查容器 restart 策略..."
    local containers
    containers="$(docker ps -a --filter "label=noda.managed=true" --format '{{.Names}}' 2>/dev/null || true)"
    if [[ -n "${containers}" ]]; then
        local name policy
        while IFS= read -r name; do
            [[ -z "${name}" ]] && continue
            policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${name}" 2>/dev/null || echo "unknown")"
            if [[ "${policy}" == "unless-stopped" ]]; then
                log_success "  ${name}: restart=${policy}"
            else
                log_warn "  ${name}: restart=${policy}（建议设为 unless-stopped）"
            fi
        done <<<"${containers}"
    else
        log_info "当前无 noda.managed=true 容器（首次部署正常）"
    fi

    # 显示系统资源概况
    log_info "=== 系统资源概况 ==="
    echo ""
    echo "内存:"
    free -m | head -2
    echo ""
    echo "Swap:"
    free -m | grep -i swap
    echo ""
    echo "Docker 数据目录磁盘:"
    df -h /mnt/mmc1-4/docker 2>/dev/null || df -h / | head -2
}

# 支持独立运行和 source 引入
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    verify_docker_autostart
fi
