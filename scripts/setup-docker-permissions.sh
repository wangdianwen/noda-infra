#!/bin/bash
set -euo pipefail

# ============================================
# 统一权限管理编排器 (Phase 34, PERM-05)
# ============================================
# 功能：一站式管理 Phase 31-34 所有权限配置
# 子命令：apply, verify, rollback, help
# 用途：管理员通过单条命令完成权限配置、验证、回滚
# 要求：需要 root 权限执行（sudo）
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 平台检测
# ============================================
detect_platform() {
    local os
    os="$(uname)"
    if [[ "$os" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

PLATFORM="$(detect_platform)"

# ============================================
# root 权限检查（help 除外）
# ============================================
if [[ $EUID -ne 0 && "${1:-}" != "help" && "${1:-}" != "--help" && "${1:-}" != "-h" ]]; then
    log_error "需要 root 权限执行，请使用: sudo bash $0 <命令>"
    exit 1
fi

# ============================================
# 子命令：apply — 按 Phase 顺序配置所有权限
# ============================================
cmd_apply() {
    log_info "=========================================="
    log_info "统一权限配置 — apply (平台: $PLATFORM)"
    log_info "=========================================="
    echo ""

    # Phase 31: Docker socket 属组 + 文件权限锁定
    log_info "Phase 31: Docker socket 属组 + 文件权限..."
    bash "$SCRIPT_DIR/apply-file-permissions.sh" apply
    log_success "Phase 31 完成"
    echo ""

    # Phase 32: sudoers 白名单规则
    log_info "Phase 32: sudoers 白名单规则..."
    bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" install
    log_success "Phase 32 完成"
    echo ""

    # Phase 33: auditd 规则 + sudo 日志
    log_info "Phase 33: auditd 审计规则..."
    bash "$SCRIPT_DIR/install-auditd-rules.sh" install
    log_info "Phase 33: sudo 操作日志..."
    bash "$SCRIPT_DIR/install-sudo-log.sh" install
    log_success "Phase 33 完成"
    echo ""

    # Phase 34: Jenkins 权限矩阵
    log_info "Phase 34: Jenkins 权限矩阵..."
    bash "$SCRIPT_DIR/setup-jenkins.sh" apply-matrix-auth
    log_success "Phase 34 完成"
    echo ""

    log_success "=========================================="
    log_success "所有权限配置完成 (Phase 31-34)"
    log_success "=========================================="
    log_info "建议运行 'sudo bash $0 verify' 验证配置"
}

# ============================================
# verify_item — 单项验证辅助函数
# ============================================
# 参数：$1 = 检查项描述，$2... = 要执行的命令
# 输出：[PASS] 或 [FAIL] 前缀
# 行为：第一个 FAIL 即退出（快速失败模式 D-12）
verify_item() {
    local desc="$1"
    shift
    set +e
    if "$@" > /dev/null 2>&1; then
        echo "[PASS] ${desc}"
    else
        echo "[FAIL] ${desc}"
        set -e
        return 1
    fi
    set -e
}

# ============================================
# 子命令：verify — 汇总所有 Phase 验证
# ============================================
cmd_verify() {
    log_info "=========================================="
    log_info "统一权限验证 — verify (平台: $PLATFORM)"
    log_info "=========================================="
    echo ""

    # Phase 31: Docker socket + 文件权限
    verify_item "Phase 31: Docker socket + 文件权限" \
        bash "$SCRIPT_DIR/apply-file-permissions.sh" verify

    # Phase 32: sudoers 白名单
    verify_item "Phase 32: sudoers 白名单" \
        bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" verify

    # Phase 33: auditd 规则
    verify_item "Phase 33: auditd 规则" \
        bash "$SCRIPT_DIR/install-auditd-rules.sh" verify

    # Phase 33: sudo 日志
    verify_item "Phase 33: sudo 日志" \
        bash "$SCRIPT_DIR/install-sudo-log.sh" verify

    # Phase 34: Jenkins 权限矩阵
    verify_item "Phase 34: Jenkins 权限矩阵" \
        bash "$SCRIPT_DIR/setup-jenkins.sh" verify-matrix-auth

    echo ""
    log_success "所有 Phase 31-34 配置验证通过"
}

# ============================================
# rollback_jenkins_matrix — 回滚 Jenkins 权限矩阵为 FullControlOnceLoggedInAuthorizationStrategy
# ============================================
rollback_jenkins_matrix() {
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不支持 Jenkins 权限矩阵操作，跳过"
        return 0
    fi

    # 检查 Jenkins 是否运行
    if ! curl -sf "http://localhost:8888/login" > /dev/null 2>&1; then
        log_warn "Jenkins 未运行，跳过权限矩阵回滚"
        return 0
    fi

    # 查找 jenkins-cli.jar
    local jhome="/var/lib/jenkins"
    local cli_jar=""
    local possible_paths=(
        "${jhome}/war/WEB-INF/jenkins-cli.jar"
        "${jhome}/jenkins-cli.jar"
        "/usr/share/jenkins/jenkins-cli.jar"
        "/usr/share/java/jenkins-cli.jar"
    )

    for path in "${possible_paths[@]}"; do
        if sudo test -f "$path"; then
            cli_jar="$path"
            break
        fi
    done

    if [ -z "$cli_jar" ]; then
        log_warn "未找到 jenkins-cli.jar，跳过 Jenkins 权限矩阵回滚"
        return 0
    fi

    log_info "回滚 Jenkins 权限矩阵为 FullControlOnceLoggedInAuthorizationStrategy..."

    # 创建临时 Groovy 回滚脚本
    local rollback_script
    rollback_script=$(mktemp /tmp/rollback-matrix-auth.groovy.XXXXXX)
    cat > "$rollback_script" <<'ROLLBACK_GROOVY'
import jenkins.model.*
import hudson.security.*

def instance = Jenkins.getInstance()

// 恢复为 FullControlOnceLoggedInAuthorizationStrategy
def strategy = new FullControlOnceLoggedInAuthorizationStrategy()
strategy.setAllowAnonymousRead(false)
instance.setAuthorizationStrategy(strategy)

// 删除 developer 用户（如果存在）
def realm = instance.getSecurityRealm()
if (realm instanceof HudsonPrivateSecurityRealm) {
    def devUser = realm.getUser('developer')
    if (devUser != null) {
        devUser.delete()
        println "Deleted developer user"
    }
}

instance.save()
println "Authorization strategy reverted to FullControlOnceLoggedInAuthorizationStrategy"
ROLLBACK_GROOVY

    # 执行回滚脚本
    local rollback_output
    rollback_output=$(sudo -u jenkins java -jar "$cli_jar" -s "http://localhost:8888/" groovy < "$rollback_script" 2>&1) || {
        log_warn "Jenkins 权限矩阵回滚执行失败（可能权限矩阵未配置）"
        log_warn "输出: ${rollback_output}"
        rm -f "$rollback_script"
        return 0
    }

    rm -f "$rollback_script"
    echo "$rollback_output"
    log_success "Jenkins 权限矩阵已回滚"
}

# ============================================
# 子命令：rollback — 反序回滚所有权限配置
# ============================================
cmd_rollback() {
    log_info "=========================================="
    log_info "统一权限回滚 — rollback (平台: $PLATFORM)"
    log_info "=========================================="
    echo ""

    # 交互确认（D-09）
    echo "将要回滚以下配置："
    echo "  Phase 34: Jenkins 权限矩阵 → FullControlOnceLoggedInAuthorizationStrategy，删除 developer 用户"
    echo "  Phase 33: 卸载 auditd 规则 + sudo 日志配置"
    echo "  Phase 32: 卸载 sudoers 白名单规则"
    echo "  Phase 31: 恢复 Docker socket 属组为 root:docker，移除 systemd override"
    echo ""
    echo -n "输入 YES 确认回滚: "
    local confirm
    read -r confirm
    if [[ "$confirm" != "YES" ]]; then
        log_info "回滚已取消"
        return 0
    fi
    echo ""

    # Phase 34: Jenkins 权限矩阵回滚
    log_info "Phase 34: 回滚 Jenkins 权限矩阵..."
    rollback_jenkins_matrix
    log_success "Phase 34 回滚完成"
    echo ""

    # Phase 33: auditd 规则 + sudo 日志卸载
    log_info "Phase 33: 卸载 sudo 日志配置..."
    bash "$SCRIPT_DIR/install-sudo-log.sh" uninstall
    log_info "Phase 33: 卸载 auditd 规则..."
    bash "$SCRIPT_DIR/install-auditd-rules.sh" uninstall
    log_success "Phase 33 回滚完成"
    echo ""

    # Phase 32: sudoers 白名单卸载
    log_info "Phase 32: 卸载 sudoers 白名单规则..."
    bash "$SCRIPT_DIR/install-sudoers-whitelist.sh" uninstall
    log_success "Phase 32 回滚完成"
    echo ""

    # Phase 31: 权限恢复
    log_info "Phase 31: 恢复 Docker socket + 文件权限..."
    bash "$SCRIPT_DIR/undo-permissions.sh" undo
    log_success "Phase 31 回滚完成"
    echo ""

    log_success "=========================================="
    log_success "所有权限配置已回滚 (Phase 34→33→32→31)"
    log_success "=========================================="
}

# ============================================
# usage() — 显示帮助信息
# ============================================
usage() {
    cat <<EOF
统一权限管理编排器 (Phase 31-34)

用法: sudo $(basename "$0") <命令>

命令:
  apply     按 Phase 顺序配置所有权限（31→32→33→34）
  verify    验证所有权限配置，输出 [PASS/FAIL] 格式（快速失败模式）
  rollback  反序回滚所有权限配置（34→33→32→31），执行前需确认
  help      显示此帮助信息

编排的脚本:
  Phase 31: apply-file-permissions.sh (apply/verify) + undo-permissions.sh (undo)
  Phase 32: install-sudoers-whitelist.sh (install/verify/uninstall)
  Phase 33: install-auditd-rules.sh (install/verify/uninstall) + install-sudo-log.sh (install/verify/uninstall)
  Phase 34: setup-jenkins.sh (apply-matrix-auth/verify-matrix-auth)

示例:
  sudo bash $0 apply       # 一键配置所有权限
  sudo bash $0 verify      # 验证所有权限配置
  sudo bash $0 rollback    # 回滚所有权限配置

平台兼容:
  macOS:  各子脚本自行处理跳过逻辑（编排器无需特殊处理）
  Linux:  完整执行所有配置
EOF
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    apply)    cmd_apply ;;
    verify)   cmd_verify ;;
    rollback) cmd_rollback ;;
    help|--help|-h) usage ;;
    *) usage && exit 1 ;;
esac
