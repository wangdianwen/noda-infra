#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/log.sh"

# ============================================
# 安全防护验证脚本（Phase 56-01）
# ============================================
# 功能：验证安全防护机制是否正确配置
# 用途：定期检查或部署后验证
# ============================================

# 验证 upstream 文件权限
verify_upstream_permissions() {
    log_info "验证 upstream 文件权限..."

    # 检查 prod upstream 文件
    if [ ! -f "/opt/noda/upstream/upstream.conf" ]; then
        log_error "Prod upstream 文件不存在: /opt/noda/upstream/upstream.conf"
        return 1
    fi

    # 检查 pre-prod upstream 文件
    if [ ! -f "/opt/noda/upstream/_preprod_upstream.conf" ]; then
        log_error "Pre-prod upstream 文件不存在: /opt/noda/upstream/_preprod_upstream.conf"
        return 1
    fi

    # 检查文件所有者（应该是 jenkins 用户）
    local prod_owner preprod_owner
    if stat -c "%U" "/opt/noda/upstream/upstream.conf" >/dev/null 2>&1; then
        prod_owner=$(stat -c "%U" "/opt/noda/upstream/upstream.conf")
        preprod_owner=$(stat -c "%U" "/opt/noda/upstream/_preprod_upstream.conf")
    else
        # macOS 兼容：使用 stat -f '%Su'
        prod_owner=$(stat -f '%Su' "/opt/noda/upstream/upstream.conf")
        preprod_owner=$(stat -f '%Su' "/opt/noda/upstream/_preprod_upstream.conf")
    fi

    if [ "$prod_owner" != "jenkins" ]; then
        log_warning "Prod upstream 文件所有者不是 jenkins: $prod_owner"
        log_warning "建议运行: sudo chown jenkins:jenkins /opt/noda/upstream/upstream.conf"
    fi

    if [ "$preprod_owner" != "jenkins" ]; then
        log_warning "Pre-prod upstream 文件所有者不是 jenkins: $preprod_owner"
        log_warning "建议运行: sudo chown jenkins:jenkins /opt/noda/upstream/_preprod_upstream.conf"
    fi

    # 检查文件权限
    local prod_perms preprod_perms
    if stat -c "%a" "/opt/noda/upstream/upstream.conf" >/dev/null 2>&1; then
        prod_perms=$(stat -c "%a" "/opt/noda/upstream/upstream.conf")
        preprod_perms=$(stat -c "%a" "/opt/noda/upstream/_preprod_upstream.conf")
    else
        # macOS 兼容：使用 stat -f '%Lp'
        prod_perms=$(stat -f '%Lp' "/opt/noda/upstream/upstream.conf")
        preprod_perms=$(stat -f '%Lp' "/opt/noda/upstream/_preprod_upstream.conf")
    fi

    if [ "$prod_perms" != "644" ]; then
        log_warning "Prod upstream 文件权限不正确: $prod_perms（期望: 644）"
    fi

    if [ "$preprod_perms" != "644" ]; then
        log_warning "Pre-prod upstream 文件权限不正确: $preprod_perms（期望: 644）"
    fi

    log_success "Upstream 文件权限验证完成"
}

# 验证内容隔离
verify_content_isolation() {
    log_info "验证内容隔离..."

    # 检查 prod 不包含 preprod 标识
    if grep -q "noda-apps-preprod" /opt/noda/upstream/upstream.conf; then
        log_error "Prod upstream 包含 preprod 标识"
        return 1
    fi

    # 检查 preprod 包含标识
    if ! grep -q "noda-apps-preprod" /opt/noda/upstream/_preprod_upstream.conf; then
        log_error "Pre-prod upstream 不包含 preprod 标识"
        return 1
    fi

    log_success "内容隔离验证通过"
}

# 验证 Jenkins Jobs
verify_jobs_exist() {
    log_info "验证 Jenkins Jobs..."

    # 检查必要的 Jobs
    local required_jobs=(
        "noda-apps-preprod-deploy"
        "noda-apps-promote"
    )

    # 尝试从环境变量加载 Jenkins 凭据
    local jenkins_url="${JENKINS_URL:-http://localhost:8888}"
    local jenkins_user="${JENKINS_ADMIN_USER:-}"
    local jenkins_password="${JENKINS_ADMIN_PASSWORD:-}"

    if [ -z "$jenkins_user" ] || [ -z "$jenkins_password" ]; then
        log_warning "Jenkins 凭据未设置，跳过 Job 验证"
        log_warning "设置环境变量 JENKINS_ADMIN_USER 和 JENKINS_ADMIN_PASSWORD 以启用验证"
        return 0
    fi

    for job in "${required_jobs[@]}"; do
        if ! curl -sf -u "$jenkins_user:$jenkins_password" \
            "$jenkins_url/job/$job/api/json" >/dev/null 2>&1; then
            log_error "Jenkins Job 不存在: $job"
            return 1
        fi
    done

    log_success "Jenkins Jobs 验证通过"
}

# 验证状态文件
verify_state_files() {
    log_info "验证状态文件..."

    # 检查 prod 状态文件
    if [ ! -f "/opt/noda/active-env" ]; then
        log_warning "Prod 状态文件不存在: /opt/noda/active-env"
    fi

    # 检查 pre-prod 状态文件
    if [ ! -f "/opt/noda/preprod/active-env" ]; then
        log_warning "Pre-prod 状态文件不存在: /opt/noda/preprod/active-env"
    fi

    log_success "状态文件验证完成"
}

# 主函数
main() {
    log_info "开始安全防护验证..."

    local has_errors=0

    # 执行验证
    verify_upstream_permissions || has_errors=1
    verify_content_isolation || has_errors=1
    verify_jobs_exist || has_errors=1
    verify_state_files || has_errors=1

    if [ $has_errors -eq 0 ]; then
        log_success "所有安全防护验证通过"
        return 0
    else
        log_error "安全防护验证失败"
        return 1
    fi
}

# 执行主函数
main "$@"
