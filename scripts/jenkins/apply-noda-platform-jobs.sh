#!/bin/bash
set -euo pipefail

# ============================================
# 应用 noda-platform Jenkins Pipeline Jobs
# ============================================
# 功能：在已运行的 Jenkins 上创建 noda-platform 的 Pipeline Jobs
#        - noda-data-migration Pipeline
#        - noda-prod-deploy Pipeline
# 前提：Doppler CLI 已通过 doppler login 认证
# 用法：bash scripts/jenkins/apply-noda-platform-jobs.sh
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

JENKINS_PORT=8080
JENKINS_URL="http://localhost:${JENKINS_PORT}"
GROOVY_DIR="$SCRIPT_DIR/init.groovy.d"
ADMIN_ENV_FILE="$SCRIPT_DIR/config/jenkins-admin.env"

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

# 通过 Jenkins REST API 执行 Groovy 脚本
run_groovy()
{
    local script_file="$1"
    local script_name
    script_name="$(basename "$script_file")"

    if [ ! -f "$script_file" ]; then
        log_error "脚本不存在: ${script_file}"
        return 1
    fi

    log_info "执行: ${script_name}"
    local script_content
    script_content="$(cat "$script_file")"

    local output
    output=$(curl -sf "${JENKINS_URL}/scriptText" \
        -u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}" \
        --data-urlencode "script=${script_content}" 2>&1)

    echo "$output"

    if echo "$output" | grep -qi "error\|exception\|failed"; then
        log_error "${script_name} 执行异常，请检查上方输出"
        return 1
    fi
}

# ============================================
# 主流程
# ============================================

log_info "=========================================="
log_info "配置 noda-platform Jenkins Pipeline Jobs"
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

# 执行 groovy 脚本
log_info "------------------------------------------"
log_info "步骤 1/2: 创建 noda-data-migration Pipeline"
log_info "------------------------------------------"
run_groovy "$GROOVY_DIR/11-pipeline-job-data-migration.groovy"

log_info "------------------------------------------"
log_info "步骤 2/2: 创建 noda-prod-deploy Pipeline"
log_info "------------------------------------------"
run_groovy "$GROOVY_DIR/12-pipeline-job-prod-deploy.groovy"

log_info "=========================================="
log_success "配置完成！"
log_info "=========================================="
log_info "Pipeline Jobs:"
log_info "  - noda-data-migration: http://localhost:${JENKINS_PORT}/job/noda-data-migration/"
log_info "  - noda-prod-deploy:    http://localhost:${JENKINS_PORT}/job/noda-prod-deploy/"
log_info ""
log_info "执行顺序:"
log_info "  1. noda-data-migration (DRY_RUN=true → 预检)"
log_info "  2. noda-data-migration (DRY_RUN=false, RUN_KEYCLOAK=true → 正式迁移)"
log_info "  3. noda-prod-deploy (TAG=latest → 全量部署)"
