#!/bin/bash
set -euo pipefail

# ============================================
# Break-Glass 紧急部署脚本
# ============================================
# 功能：当 Jenkins 不可用时，管理员通过此脚本验证身份后执行紧急部署
# 安全机制：
#   - Jenkins 可用时拒绝执行（D-02）
#   - 需要 sudo 密码验证（D-01）
#   - 所有操作记录到审计日志（BREAK-03）
#   - 仅允许调用指定部署脚本（D-03）
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/platform.sh"

PLATFORM="$(detect_platform)"

# ============================================
# 常量
# ============================================
JENKINS_PORT=8888
JENKINS_HEALTH_URL="http://localhost:${JENKINS_PORT}/login"
JENKINS_HEALTH_TIMEOUT=10
AUDIT_LOG="/var/log/noda/break-glass.log"
ALLOWED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
)

# ============================================
# check_jenkins_available() — Jenkins 可用性检查（D-02, BREAK-04）
# ============================================
# 返回：0=可用（拒绝 Break-Glass），1=不可用（允许 Break-Glass）
check_jenkins_available()
{
    log_info "检查 Jenkins 可用性..."
    log_info "端点: $JENKINS_HEALTH_URL (超时: ${JENKINS_HEALTH_TIMEOUT}s)"

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$JENKINS_HEALTH_TIMEOUT" \
        --max-time "$JENKINS_HEALTH_TIMEOUT" \
        "$JENKINS_HEALTH_URL" 2>/dev/null) || http_code="000"

    if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "403" ]; then
        # 200/302/403 都说明 Jenkins 进程在响应（403 是需要登录但进程正常）
        log_success "Jenkins 正在运行 (HTTP $http_code)"
        return 0
    else
        log_info "Jenkins 不可用 (HTTP $http_code)"
        return 1
    fi
}

# ============================================
# verify_identity() — PAM 身份验证（D-01, BREAK-03）
# ============================================
# 使用 sudo -v 验证用户身份（触发 PAM 密码验证）
# 返回：0=验证通过，1=验证失败
verify_identity()
{
    log_info "身份验证（需要 sudo 密码）..."

    if sudo -v; then
        log_success "身份验证通过: $(whoami)"
        return 0
    else
        log_error "身份验证失败"
        return 1
    fi
}

# ============================================
# log_audit() — 审计日志记录（BREAK-03）
# ============================================
log_audit()
{
    local action="$1"
    local detail="${2:-}"

    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

    # 确保 /var/log/noda/ 目录存在
    sudo mkdir -p "$(dirname "$AUDIT_LOG")"

    local log_entry
    log_entry="[$timestamp] user=$(whoami) action=$action detail=$detail"

    echo "$log_entry" | sudo tee -a "$AUDIT_LOG" >/dev/null
    sudo chmod 640 "$AUDIT_LOG"
    sudo chown root:jenkins "$AUDIT_LOG" 2>/dev/null || true
}

# ============================================
# validate_script() — 验证目标脚本在允许列表中（D-03）
# ============================================
validate_script()
{
    local target_script="$1"

    for allowed in "${ALLOWED_SCRIPTS[@]}"; do
        if [ "$target_script" = "$allowed" ] || [ "$target_script" = "$(basename "$allowed")" ]; then
            return 0
        fi
    done

    log_error "脚本不在允许列表中: $target_script"
    log_info "允许的脚本:"
    for allowed in "${ALLOWED_SCRIPTS[@]}"; do
        log_info "  - $(basename "$allowed")"
    done
    return 1
}

# ============================================
# cmd_deploy() — 执行紧急部署（核心逻辑）
# ============================================
cmd_deploy()
{
    local target_script="${1:-}"
    local script_args="${@:2}"

    if [ -z "$target_script" ]; then
        log_error "请指定部署脚本"
        log_info "用法: $0 deploy <脚本名> [参数...]"
        log_info "允许的脚本:"
        for allowed in "${ALLOWED_SCRIPTS[@]}"; do
            log_info "  - $(basename "$allowed")"
        done
        exit 1
    fi

    # macOS 检查
    if [[ "$(uname)" == "Darwin" ]]; then
        log_warn "macOS 环境：跳过 Jenkins 可用性检查"
    else
        # 步骤 1/4: 检查 Jenkins 不可用（BREAK-04, D-02）
        if check_jenkins_available; then
            log_error "=========================================="
            log_error "Jenkins 正在运行！请使用 Jenkins Pipeline 部署。"
            log_error "Break-Glass 仅在 Jenkins 不可用时使用。"
            log_error "=========================================="
            log_audit "BREAK_GLASS_DENIED" "jenkins_available"
            exit 1
        fi
    fi

    # 步骤 2/4: 验证目标脚本（D-03）
    # 支持简写名或完整路径
    local resolved_script=""
    for allowed in "${ALLOWED_SCRIPTS[@]}"; do
        if [ "$target_script" = "$allowed" ] || [ "$target_script" = "$(basename "$allowed")" ]; then
            resolved_script="$allowed"
            break
        fi
    done

    if [ -z "$resolved_script" ]; then
        log_error "脚本不在允许列表中: $target_script"
        log_info "允许的脚本:"
        for allowed in "${ALLOWED_SCRIPTS[@]}"; do
            log_info "  - $(basename "$allowed")"
        done
        log_audit "BREAK_GLASS_DENIED" "script_not_allowed:$target_script"
        exit 1
    fi

    if [ ! -f "$resolved_script" ]; then
        log_error "脚本文件不存在: $resolved_script"
        exit 1
    fi

    # 步骤 3/4: 身份验证（D-01, BREAK-03）
    if ! verify_identity; then
        log_audit "BREAK_GLASS_DENIED" "auth_failed"
        exit 1
    fi

    # 步骤 4/4: 执行紧急部署
    log_warn "=========================================="
    log_warn "BREAK-GLASS 紧急部署"
    log_warn "=========================================="
    log_warn "操作人: $(whoami)"
    log_warn "目标脚本: $resolved_script"
    log_warn "脚本参数: ${script_args:-无}"
    log_warn "时间: $(date -Iseconds 2>/dev/null || date)"
    log_warn "=========================================="

    log_audit "BREAK_GLASS_START" "script=$(basename "$resolved_script") args=$script_args"

    # 以 jenkins 用户身份执行部署脚本（per Phase 31 权限锁定）
    # 部署脚本权限为 750 root:jenkins，仅 jenkins 用户可执行
    local exit_code=0
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: 直接执行（无 jenkins 用户）
        bash "$resolved_script" $script_args || exit_code=$?
    else
        # Linux: 以 jenkins 用户执行
        sudo -u jenkins bash "$resolved_script" $script_args || exit_code=$?
    fi

    if [ $exit_code -eq 0 ]; then
        log_success "=========================================="
        log_success "BREAK-GLASS 紧急部署完成"
        log_success "=========================================="
        log_audit "BREAK_GLASS_SUCCESS" "script=$(basename "$resolved_script")"
    else
        log_error "=========================================="
        log_error "BREAK-GLASS 紧急部署失败 (exit code: $exit_code)"
        log_error "=========================================="
        log_audit "BREAK_GLASS_FAILED" "script=$(basename "$resolved_script") exit_code=$exit_code"
        exit $exit_code
    fi
}

# ============================================
# cmd_status() — 显示 Break-Glass 状态
# ============================================
cmd_status()
{
    log_info "=========================================="
    log_info "Break-Glass 状态"
    log_info "=========================================="

    # Jenkins 状态
    if [[ "$(uname)" == "Darwin" ]]; then
        log_warn "平台: macOS（生产环境功能，此处仅供参考）"
    else
        if check_jenkins_available; then
            log_success "Jenkins: 运行中（Break-Glass 将被拒绝）"
        else
            log_warn "Jenkins: 不可用（Break-Glass 可用）"
        fi
    fi

    # 审计日志
    if [ -f "$AUDIT_LOG" ]; then
        log_info "审计日志: $AUDIT_LOG"
        log_info "最近 5 条记录:"
        sudo tail -5 "$AUDIT_LOG" 2>/dev/null | sed 's/^/  /'
    else
        log_info "审计日志: 无记录"
    fi

    # 允许的脚本
    log_info "允许的部署脚本:"
    for allowed in "${ALLOWED_SCRIPTS[@]}"; do
        if [ -f "$allowed" ]; then
            log_success "  $(basename "$allowed") — 存在"
        else
            log_error "  $(basename "$allowed") — 不存在"
        fi
    done
}

# ============================================
# cmd_log() — 查看审计日志
# ============================================
cmd_log()
{
    if [ ! -f "$AUDIT_LOG" ]; then
        log_info "审计日志为空: $AUDIT_LOG"
        return 0
    fi

    log_info "Break-Glass 审计日志: $AUDIT_LOG"
    log_info "=========================================="
    sudo cat "$AUDIT_LOG"
}

# ============================================
# 用法说明
# ============================================
usage()
{
    cat <<EOF
用法: $(basename "$0") <命令> [参数]

命令:
  deploy <脚本名> [参数...]  执行紧急部署（仅 Jenkins 不可用时可用）
  status                     显示 Break-Glass 状态和 Jenkins 可用性
  log                        查看审计日志

允许的部署脚本 (D-03):
  deploy-apps-prod.sh        部署应用服务（findclass-ssr, noda-site）
  deploy-infrastructure-prod.sh  部署基础设施（PostgreSQL 等）

安全机制:
  - Jenkins 可用时拒绝执行（D-02）
  - 需要 sudo 密码验证（D-01）
  - 所有操作记录到审计日志（BREAK-03）
  - 仅允许调用指定部署脚本（D-03）

审计日志: /var/log/noda/break-glass.log

示例:
  $(basename "$0") status
  $(basename "$0") deploy deploy-apps-prod.sh
  $(basename "$0") deploy deploy-infrastructure-prod.sh --skip-backup
  $(basename "$0") log
EOF
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    deploy) cmd_deploy "${@:2}" ;;
    status) cmd_status ;;
    log) cmd_log ;;
    help | --help | -h) usage ;;
    *) usage && exit 1 ;;
esac
