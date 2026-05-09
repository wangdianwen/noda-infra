#!/bin/bash
set -euo pipefail

# ============================================
# Docker 网络别名验证脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# verify_network_alias - 验证容器的网络别名
verify_network_alias()
{
    local service_name="$1"
    local expected_alias="$2"
    local container_name

    container_name=$(docker ps --filter "name=$service_name" --format "{{.Names}}" | head -1)

    if [ -z "$container_name" ]; then
        log_error "容器不存在: $service_name"
        return 1
    fi

    local actual_alias
    actual_alias=$(docker inspect "$container_name" --format='{{range $net, $conf := .NetworkSettings.Networks}}{{if eq $net "noda-net"}}{{range $conf.Aliases}}{{println .}}{{end}}{{end}}{{end}}' 2>/dev/null || echo "")

    if echo "$actual_alias" | grep -q "$expected_alias"; then
        log_success "网络别名正确: $expected_alias (容器: $container_name)"
        return 0
    else
        log_error "网络别名不匹配。期望: $expected_alias, 实际: $actual_alias (容器: $container_name)"
        return 1
    fi
}

# 主函数
main()
{
    local action="${1:-verify}"

    case "$action" in
        verify)
            if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
                log_error "用法: $0 verify <容器名> <期望别名>"
                exit 1
            fi
            verify_network_alias "$2" "$3"
            ;;
        *)
            echo "用法: $0 verify <容器名> <期望别名>"
            exit 1
            ;;
    esac
}

main "$@"
