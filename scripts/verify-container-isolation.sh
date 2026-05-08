#!/bin/bash
set -euo pipefail

# ============================================
# 容器隔离验证脚本
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# verify_container_isolation - 验证容器隔离
# 返回：0=隔离正确，1=隔离有问题
verify_container_isolation()
{
    log_info "验证容器隔离..."

    local has_error=0

    # 检查容器名称是否隔离
    local prod_containers
    prod_containers=$(docker ps --filter "name=noda-apps" --format "{{.Names}}" | grep -v "preprod" || true)

    local preprod_containers
    preprod_containers=$(docker ps --filter "name=noda-apps-preprod" --format "{{.Names}}" || true)

    # 检查 prod 容器是否包含 preprod
    if echo "$prod_containers" | grep -q "preprod"; then
        log_error "Prod 容器名称包含 preprod，未隔离: $prod_containers"
        has_error=1
    else
        log_success "Prod 容器名称已隔离"
    fi

    # 检查 preprod 容器是否都包含 preprod
    if [ -n "$preprod_containers" ]; then
        if echo "$preprod_containers" | grep -q -v "preprod"; then
            log_error "Pre-prod 容器名称不包含 preprod，未隔离: $preprod_containers"
            has_error=1
        else
            log_success "Pre-prod 容器名称已隔离"
        fi
    else
        log_warn "未发现 Pre-prod 容器（可能未部署）"
    fi

    # 检查网络别名
    if ! "$SCRIPT_DIR/verify-network-alias.sh" conflicts; then
        log_error "网络别名冲突检查失败"
        has_error=1
    fi

    if [ $has_error -eq 0 ]; then
        log_success "容器隔离验证通过"
    fi

    return $has_error
}

# verify_environment_variables - 验证环境变量隔离
# 返回：0=隔离正确，1=隔离有问题
verify_environment_variables()
{
    log_info "验证环境变量隔离..."

    local has_error=0

    # 检查 prod 容器的数据库连接（如果存在）
    local prod_container
    prod_container=$(docker ps --filter "name=noda-apps-prod" --format "{{.Names}}" | head -1 || true)

    if [ -n "$prod_container" ]; then
        local prod_db
        prod_db=$(docker exec "$prod_container" env 2>/dev/null | grep DATABASE_URL | cut -d= -f2 || echo "")

        if echo "$prod_db" | grep -q "noda_preprod"; then
            log_error "Prod 容器连接到 preprod 数据库: $prod_container"
            has_error=1
        else
            log_success "Prod 容器数据库连接正确"
        fi
    fi

    # 检查 preprod 容器的数据库连接（如果存在）
    local preprod_container
    preprod_container=$(docker ps --filter "name=noda-apps-preprod" --format "{{.Names}}" | head -1 || true)

    if [ -n "$preprod_container" ]; then
        local preprod_db
        preprod_db=$(docker exec "$preprod_container" env 2>/dev/null | grep DATABASE_URL | cut -d= -f2 || echo "")

        if ! echo "$preprod_db" | grep -q "noda_preprod"; then
            log_error "Pre-prod 容器未连接到 preprod 数据库: $preprod_container"
            has_error=1
        else
            log_success "Pre-prod 容器数据库连接正确"
        fi
    fi

    if [ $has_error -eq 0 ]; then
        log_success "环境变量隔离验证通过"
    fi

    return $has_error
}

# 主函数
main()
{
    local action="${1:-isolation}"

    case "$action" in
        isolation)
            verify_container_isolation
            ;;
        env)
            verify_environment_variables
            ;;
        all)
            verify_container_isolation
            verify_environment_variables
            ;;
        *)
            echo "用法: $0 <isolation|env|all>"
            echo ""
            echo "命令:"
            echo "  isolation  验证容器隔离"
            echo "  env        验证环境变量隔离"
            echo "  all        验证所有隔离项"
            exit 1
            ;;
    esac
}

main "$@"
