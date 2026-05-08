#!/bin/bash
set -euo pipefail

# ============================================
# 删除 Jenkins 中的 noda-apps-deploy Pipeline Job
# ============================================
# 功能：从已运行的 Jenkins 中删除 noda-apps-deploy 和 findclass-ssr-deploy jobs
# 前提：Jenkins 正在运行，管理员凭据已配置
# 用法：bash scripts/jenkins/delete-noda-apps-job.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

JENKINS_PORT=8888
JENKINS_URL="http://localhost:${JENKINS_PORT}"
ADMIN_ENV_FILE="$SCRIPT_DIR/config/jenkins-admin.env"
GROOVY_SCRIPT="$SCRIPT_DIR/init.groovy.d/99-delete-noda-apps-deploy.groovy"

# 加载管理员凭据
load_admin_credentials()
{
    if [ ! -f "$ADMIN_ENV_FILE" ]; then
        log_error "未找到凭据文件: ${ADMIN_ENV_FILE}"
        exit 1
    fi
    source "$ADMIN_ENV_FILE"
    if [[ -z "${JENKINS_ADMIN_USER:-}" || -z "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
        log_error "凭据文件中缺少 JENKINS_ADMIN_USER 或 JENKINS_ADMIN_PASSWORD"
        exit 1
    fi
}

# 执行 Groovy 脚本
run_groovy()
{
    local script_file="$1"

    if [ ! -f "$script_file" ]; then
        log_error "脚本不存在: ${script_file}"
        return 1
    fi

    local script_content
    script_content="$(cat "$script_file")"

    local output
    output=$(curl -sf "${JENKINS_URL}/scriptText" \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        --data-urlencode "script=${script_content}" 2>&1)

    echo "$output"

    if echo "$output" | grep -qi "error\|exception\|failed"; then
        log_error "脚本执行异常"
        return 1
    fi
}

# ============================================
# 主流程
# ============================================

log_info "=========================================="
log_info "删除 noda-apps-deploy Pipeline Jobs"
log_info "=========================================="

# 检查 Jenkins 是否运行
if ! curl -sf "${JENKINS_URL}/login" >/dev/null 2>&1; then
    log_error "Jenkins 未运行: ${JENKINS_URL}"
    log_info "启动命令: bash ${PROJECT_ROOT}/scripts/setup-jenkins.sh restart"
    exit 1
fi
log_success "Jenkins 运行中"

# 加载凭据
load_admin_credentials
log_success "管理员凭据已加载"

# 执行删除脚本
log_info "执行删除脚本..."
run_groovy "$GROOVY_SCRIPT"

log_success "=========================================="
log_success "删除完成！"
log_success "=========================================="
log_info "已删除的 jobs:"
log_info "  - noda-apps-deploy"
log_info "  - findclass-ssr-deploy"
log_info ""
log_info "Jenkins Dashboard: http://localhost:${JENKINS_PORT}/"
