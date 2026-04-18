#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SUDOERS_FILE="/etc/sudoers.d/noda-audit"
SUDO_LOG_DIR="/var/log/sudo-logs"
SUDO_LOG_FILE="$SUDO_LOG_DIR/sudo.log"
LOGROTATE_SRC="$PROJECT_ROOT/config/logrotate/sudo-logs"
LOGROTATE_DST="/etc/logrotate.d/sudo-logs"
BACKUP_DIR="/opt/noda/pre-phase33-backup"

source "$PROJECT_ROOT/scripts/lib/log.sh"
source "$PROJECT_ROOT/scripts/lib/platform.sh"

PLATFORM="$(detect_platform)"

# ============================================
# 子命令：install — 安装 sudo 日志配置
# ============================================
cmd_install() {
    log_info "Phase 33: 安装 sudo 操作日志配置 (平台: $PLATFORM)..."

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 sudo 日志配置，跳过安装"
        return 0
    fi

    # 2. 创建 sudo 日志目录
    log_info "创建 sudo 日志目录: $SUDO_LOG_DIR..."
    mkdir -p "$SUDO_LOG_DIR"
    chmod 700 "$SUDO_LOG_DIR"
    chown root:root "$SUDO_LOG_DIR"
    log_success "日志目录已创建: $SUDO_LOG_DIR (权限: 700 root:root)"

    # 3. 创建初始日志文件
    touch "$SUDO_LOG_FILE"
    chmod 0600 "$SUDO_LOG_FILE"
    chown root:root "$SUDO_LOG_FILE"
    log_success "初始日志文件已创建: $SUDO_LOG_FILE (权限: 0600 root:root)"

    # 4. 备份现有 sudoers 文件
    if [ -f "$SUDOERS_FILE" ]; then
        log_info "备份现有 sudoers 文件到 $BACKUP_DIR/noda-audit.bak..."
        mkdir -p "$BACKUP_DIR"
        cp "$SUDOERS_FILE" "$BACKUP_DIR/noda-audit.bak"
        log_success "备份完成"
    fi

    # 5. 写入 sudoers 配置文件
    log_info "写入 sudoers 配置文件: $SUDOERS_FILE..."
    tee "$SUDOERS_FILE" > /dev/null <<'EOF'
# Noda Sudo Audit Log Configuration (Phase 33, AUDIT-04)
# 将所有 sudo 操作记录到独立日志文件

Defaults logfile=/var/log/sudo-logs/sudo.log
EOF

    # 6. 验证 sudoers 语法
    log_info "验证 sudoers 语法..."
    if ! visudo -cf "$SUDOERS_FILE"; then
        log_error "sudoers 语法验证失败，删除无效文件"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    log_success "sudoers 语法验证通过"

    # 7. 设置文件权限
    chmod 0440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    log_success "文件权限已设置: 0440 root:root"

    # 8. 复制 logrotate 配置
    if [ -f "$LOGROTATE_SRC" ]; then
        log_info "复制 logrotate 配置..."
        cp "$LOGROTATE_SRC" "$LOGROTATE_DST"
        chmod 0644 "$LOGROTATE_DST"
        log_success "logrotate 配置已安装: $LOGROTATE_DST"
    else
        log_warn "logrotate 配置源文件不存在: $LOGROTATE_SRC"
    fi

    # 9. 输出安装成功信息
    echo ""
    log_success "Phase 33: sudo 操作日志配置安装完成"
    echo ""
    log_info "sudoers 文件: $SUDOERS_FILE"
    log_info "日志路径: $SUDO_LOG_FILE"
    log_info "logrotate: $LOGROTATE_DST"
    echo ""
    log_info "建议运行 'sudo bash $0 verify' 验证安装"
}

# ============================================
# 子命令：verify — 验证 sudo 日志配置
# ============================================
cmd_verify() {
    local all_ok=true

    log_info "Phase 33: 验证 sudo 操作日志配置 (平台: $PLATFORM)..."
    echo ""

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 sudo 日志配置，跳过验证"
        return 0
    fi

    # 2. 检查 sudoers 文件存在
    if [ ! -f "$SUDOERS_FILE" ]; then
        log_error "sudoers 文件不存在: $SUDOERS_FILE"
        return 1
    fi
    log_success "sudoers 文件存在: $SUDOERS_FILE"

    # 3. 检查文件权限
    local perms owner group
    if [[ "$(uname)" == "Darwin" ]]; then
        perms="$(stat -f '%Lp' "$SUDOERS_FILE")"
        owner="$(stat -f '%Su' "$SUDOERS_FILE")"
        group="$(stat -f '%Sg' "$SUDOERS_FILE")"
    else
        perms="$(stat -c '%a' "$SUDOERS_FILE")"
        owner="$(stat -c '%U' "$SUDOERS_FILE")"
        group="$(stat -c '%G' "$SUDOERS_FILE")"
    fi

    if [[ "$perms" == "440" && "$owner" == "root" && "$group" == "root" ]]; then
        log_success "文件权限正确: 0440 root:root"
    else
        log_error "文件权限错误: $perms $owner:$group (期望: 0440 root:root)"
        all_ok=false
    fi

    # 4. 语法验证
    if ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        log_error "sudoers 语法验证失败"
        all_ok=false
    else
        log_success "sudoers 语法验证通过"
    fi

    # 5. 检查内容包含 logfile 配置
    if grep -q "logfile=/var/log/sudo-logs/sudo.log" "$SUDOERS_FILE"; then
        log_success "sudoers 包含 logfile 配置"
    else
        log_error "sudoers 缺少 logfile 配置"
        all_ok=false
    fi

    # 6. 检查日志目录存在
    if [ -d "$SUDO_LOG_DIR" ]; then
        log_success "日志目录存在: $SUDO_LOG_DIR"
    else
        log_error "日志目录不存在: $SUDO_LOG_DIR"
        all_ok=false
    fi

    # 7. 检查日志目录权限
    if [ -d "$SUDO_LOG_DIR" ]; then
        local dir_perms dir_owner dir_group
        if [[ "$(uname)" == "Darwin" ]]; then
            dir_perms="$(stat -f '%Lp' "$SUDO_LOG_DIR")"
            dir_owner="$(stat -f '%Su' "$SUDO_LOG_DIR")"
            dir_group="$(stat -f '%Sg' "$SUDO_LOG_DIR")"
        else
            dir_perms="$(stat -c '%a' "$SUDO_LOG_DIR")"
            dir_owner="$(stat -c '%U' "$SUDO_LOG_DIR")"
            dir_group="$(stat -c '%G' "$SUDO_LOG_DIR")"
        fi

        if [[ "$dir_perms" == "700" && "$dir_owner" == "root" && "$dir_group" == "root" ]]; then
            log_success "日志目录权限正确: 700 root:root"
        else
            log_error "日志目录权限错误: $dir_perms $dir_owner:$dir_group (期望: 700 root:root)"
            all_ok=false
        fi
    fi

    # 8. 检查 logrotate 配置存在
    if [ -f "$LOGROTATE_DST" ]; then
        log_success "logrotate 配置存在: $LOGROTATE_DST"
    else
        log_error "logrotate 配置不存在: $LOGROTATE_DST"
        all_ok=false
    fi

    # 9. 检查 logrotate 内容
    if [ -f "$LOGROTATE_DST" ]; then
        if grep -q "rotate 14" "$LOGROTATE_DST"; then
            log_success "logrotate: rotate 14 (14 天保留)"
        else
            log_error "logrotate 缺少 rotate 14"
            all_ok=false
        fi
    fi

    echo ""
    if $all_ok; then
        log_success "所有验证通过 (PASS)"
    else
        log_error "部分验证失败 (FAIL)"
        return 1
    fi
}

# ============================================
# 子命令：uninstall — 卸载 sudo 日志配置
# ============================================
cmd_uninstall() {
    log_info "Phase 33: 卸载 sudo 操作日志配置..."

    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 sudo 日志配置，无需卸载"
        return 0
    fi

    # 删除 sudoers 文件
    if [ -f "$SUDOERS_FILE" ]; then
        rm -f "$SUDOERS_FILE"
        log_success "已删除 sudoers 文件: $SUDOERS_FILE"
    else
        log_warn "sudoers 文件不存在: $SUDOERS_FILE"
    fi

    # 删除 logrotate 配置
    if [ -f "$LOGROTATE_DST" ]; then
        rm -f "$LOGROTATE_DST"
        log_success "已删除 logrotate 配置: $LOGROTATE_DST"
    fi

    log_success "Phase 33: sudo 操作日志配置卸载完成"
    log_info "日志目录和日志文件保留（包含历史审计数据）: $SUDO_LOG_DIR"
}

# ============================================
# 用法说明
# ============================================
usage() {
    cat <<EOF
用法: sudo $(basename "$0") <命令>

命令:
  install    安装 sudo 操作日志配置
  verify     验证 sudo 操作日志配置是否正确
  uninstall  卸载 sudo 操作日志配置
  help       显示此帮助信息

功能:
  配置 sudoers 将所有 sudo 操作记录到独立日志文件（AUDIT-04）
  日志路径: $SUDO_LOG_FILE
  日志保留: 14 天，单文件最大 50MB (D-01)

配置文件:
  sudoers: $SUDOERS_FILE
  logrotate: $LOGROTATE_DST

平台兼容:
  macOS:  跳过安装
  Linux:  安装完整 sudo 日志配置
EOF
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    install)
        cmd_install
        ;;
    verify)
        cmd_verify
        ;;
    uninstall)
        cmd_uninstall
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
