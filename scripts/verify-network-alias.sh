#!/bin/bash
set -euo pipefail

# ============================================
# Docker 网络别名验证脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# verify_network_alias - 验证容器的网络别名
# 参数:
#   $1: 容器名
#   $2: 期望的别名
# 返回：0=验证成功，1=验证失败
verify_network_alias()
{
    local service_name="$1"
    local expected_alias="$2"
    local container_name

    # 获取容器名
    container_name=$(docker ps --filter "name=$service_name" --format "{{.Names}}" | head -1)

    if [ -z "$container_name" ]; then
        log_error "容器不存在: $service_name"
        return 1
    fi

    # 验证网络别名（noda-net 网络）
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

# check_network_conflicts - 检查网络别名冲突
# 返回：0=无冲突，1=有冲突
check_network_conflicts()
{
    log_info "检查网络别名冲突..."

    local has_error=0

    # 检查 prod 别名
    if docker network inspect noda-net --format='{{range .Containers}}{{.Name}}: {{range .Aliases}}{{.}} {{end}}{{end}}' 2>/dev/null | grep -q "noda-apps "; then
        log_success "Prod 网络别名已设置"
    else
        log_error "Prod 网络别名未设置"
        has_error=1
    fi

    # 检查 pre-prod 别名
    if docker network inspect noda-net --format='{{range .Containers}}{{.Name}}: {{range .Aliases}}{{.}} {{end}}{{end}}' 2>/dev/null | grep -q "noda-apps-preprod "; then
        log_success "Pre-prod 网络别名已设置"
    else
        log_warn "Pre-prod 网络别名未设置（可能未部署）"
    fi

    # 检查是否有冲突（不应该有同时包含 noda-apps 和 preprod 的别名）
    local conflict_aliases
    conflict_aliases=$(docker network inspect noda-net --format='{{range .Containers}}{{range .Aliases}}{{println .}}{{end}}{{end}}' 2>/dev/null | grep "noda-apps" | grep "preprod" || true)

    if [ -n "$conflict_aliases" ]; then
        log_error "检测到网络别名冲突: $conflict_aliases"
        has_error=1
    else
        log_success "网络别名无冲突"
    fi

    return $has_error
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
        conflicts)
            check_network_conflicts
            ;;
        *)
            echo "用法: $0 <verify|conflicts> [参数...]"
            echo ""
            echo "命令:"
            echo "  verify <容器名> <期望别名>  验证容器的网络别名"
            echo "  conflicts                      检查网络别名冲突"
            exit 1
            ;;
    esac
}

main "$@"
