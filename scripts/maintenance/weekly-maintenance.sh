#!/bin/bash
# ============================================
# 每周主机侧维护脚本（macOS launchd 承载调度）
# ============================================
# 背景：原 Jenkins cleanup job 已删除，主机侧缓存维护失去调度承载，
#       改由 ~/Library/LaunchAgents/noda.weekly-maintenance.plist 每周日 03:30 触发。
# 职责：
#   1. Jenkins 忙碌检测：有 job 正在构建（color 含 anime）则本轮跳过，
#      避免 registry GC 与镜像推送并发冲突；Jenkins 不可达则不阻塞，继续维护。
#   2. cleanup_periodic_maintenance：
#      Jenkins workspace 清理 / registry 保留策略 + GC / pnpm store prune / npm cache clean。
# 用法：
#   weekly-maintenance.sh          普通模式（pnpm prune 受 7 天间隔限制）
#   weekly-maintenance.sh --force  强制模式（透传给 cleanup_periodic_maintenance）
# 日志：~/Library/Logs/noda-maintenance.log（launchd StandardOut/ErrPath 同指向该文件兜底）
# 注意：不用 set -e——各清理步骤互相独立，一步失败不影响后续。
# ============================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# 日志库需最先加载（忙碌检测也要写日志，且负责补全 PATH / nvm 环境）
# shellcheck disable=SC1091
. "${PROJECT_ROOT}/scripts/lib/log.sh"

LOG_DIR="${HOME}/Library/Logs"
LOG_FILE="${LOG_DIR}/noda-maintenance.log"

JENKINS_URL="http://localhost:8080"
JENKINS_ENV_FILE="${PROJECT_ROOT}/scripts/jenkins/config/jenkins-admin.env"

FORCE_MODE=""

# -------------------------------------------
# Jenkins 忙碌检测
# 返回 0 = 忙碌（正在构建，本轮应跳过）
# 返回 1 = 空闲或不可达（继续维护，不阻塞）
# -------------------------------------------
jenkins_is_busy()
{
    if [ ! -f "$JENKINS_ENV_FILE" ]; then
        log_warn "未找到 Jenkins 凭据文件，跳过忙碌检测: $JENKINS_ENV_FILE"
        return 1
    fi
    # shellcheck disable=SC1090
    . "$JENKINS_ENV_FILE"

    # URL 编码方括号（%5B/%5D），避免 curl 将 [] 解析为 URL globbing
    local response
    response=$(curl -fsS --max-time 10 \
        -u "${JENKINS_ADMIN_USER:-}:${JENKINS_ADMIN_PASSWORD:-}" \
        "${JENKINS_URL}/api/json?tree=jobs%5Bname,color%5D" 2>/dev/null) || response=""

    if [ -z "$response" ]; then
        log_warn "Jenkins API 不可达（可能未启动），不阻塞，继续维护"
        return 1
    fi

    if printf '%s' "$response" | grep -q '"color": *"[^"]*anime'; then
        log_warn "检测到 Jenkins 正在构建（job color 含 anime），本轮维护跳过，避免与镜像推送并发冲突"
        return 0
    fi

    log_info "Jenkins 空闲，继续维护"
    return 1
}

main()
{
    mkdir -p "$LOG_DIR"

    # 本脚本全部输出追加到日志文件（launchd 的 StandardOutPath/StandardErrorPath
    # 指向同一文件，仅兜底接管 exec 重定向生效前的输出）
    exec >>"$LOG_FILE" 2>&1

    # 参数解析：--force 透传给 cleanup_periodic_maintenance 做强制模式
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force) FORCE_MODE="force" ;;
            *) log_warn "未知参数（忽略）: $arg" ;;
        esac
    done

    echo "=================================================================="
    echo "== noda 每周维护开始: $(date '+%Y-%m-%d %H:%M:%S %Z') (force=${FORCE_MODE:-no})"
    echo "=================================================================="

    local start_epoch elapsed
    start_epoch=$(date +%s)

    if jenkins_is_busy; then
        echo "== 本轮维护跳过（Jenkins 忙碌）: $(date '+%Y-%m-%d %H:%M:%S') =="
        return 0
    fi

    # shellcheck disable=SC1091
    . "${PROJECT_ROOT}/scripts/lib/cleanup.sh"

    if [ -n "$FORCE_MODE" ]; then
        cleanup_periodic_maintenance "force"
    else
        cleanup_periodic_maintenance
    fi

    elapsed=$(( $(date +%s) - start_epoch ))
    log_success "本次维护完成，耗时 ${elapsed} 秒"
    echo "== noda 每周维护结束: $(date '+%Y-%m-%d %H:%M:%S') =="
    return 0
}

main "$@"
exit $?
