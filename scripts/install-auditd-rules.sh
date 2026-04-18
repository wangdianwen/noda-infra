#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RULES_FILE="/etc/audit/rules.d/noda-docker.rules"
AUDITD_CONF="/etc/audit/auditd.conf"
BACKUP_DIR="/opt/noda/pre-phase33-backup"

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
# 子命令：install — 安装 auditd 规则
# ============================================
cmd_install() {
    log_info "Phase 33: 安装 auditd Docker 审计规则 (平台: $PLATFORM)..."

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不支持 auditd，跳过安装"
        return 0
    fi

    # 2. 安装 auditd 包
    if ! dpkg -l auditd >/dev/null 2>&1; then
        log_info "安装 auditd 包..."
        apt install -y auditd audispd-plugins
    fi
    log_success "auditd 包已安装"

    # 3. 检查并移除 Debian no-audit 默认规则
    local no_audit_rules="/etc/audit/rules.d/10-no-audit.rules"
    if [ -f "$no_audit_rules" ]; then
        log_info "移除 Debian 默认 no-audit 规则: $no_audit_rules"
        rm -f "$no_audit_rules"
    fi

    # 4. 备份当前规则文件
    if [ -f "$RULES_FILE" ]; then
        log_info "备份现有规则文件到 $BACKUP_DIR/noda-docker.rules.bak..."
        mkdir -p "$BACKUP_DIR"
        cp "$RULES_FILE" "$BACKUP_DIR/noda-docker.rules.bak"
        log_success "备份完成"
    fi

    # 5. 写入 auditd 规则文件
    log_info "写入 auditd 规则文件: $RULES_FILE..."
    tee "$RULES_FILE" > /dev/null <<'EOF'
## Noda Docker Command Audit Rules (Phase 33, AUDIT-01)
## 监控所有 docker 命令执行，记录 auid/时间/命令参数

# 删除已有 docker-cmd 规则（幂等）
-D -k docker-cmd

# 监控 docker 命令执行（普通用户 auid >= 1000）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F auid>=1000 -F auid!=-1 -k docker-cmd

# 监控 jenkins 系统用户的 docker 命令（auid 可能为 unset）
-a always,exit -F arch=b64 -S execve -F exe=/usr/bin/docker -F uid=jenkins -k docker-cmd
EOF

    # 6. 设置规则文件权限
    chmod 0640 "$RULES_FILE"
    chown root:root "$RULES_FILE"
    log_success "规则文件权限已设置: 0640 root:root"

    # 7. 修改 auditd.conf
    log_info "配置 auditd.conf..."
    mkdir -p "$(dirname "$AUDITD_CONF")"

    local params=(
        "log_group=root"
        "max_log_file=50"
        "max_log_file_action=ROTATE"
        "num_logs=30"
        "log_format=ENRICHED"
    )

    for param in "${params[@]}"; do
        local key="${param%%=*}"
        local value="${param#*=}"
        if grep -q "^${key}" "$AUDITD_CONF" 2>/dev/null; then
            sed -i "s/^${key}*=.*/${key} = ${value}/" "$AUDITD_CONF"
        else
            echo "${key} = ${value}" >> "$AUDITD_CONF"
        fi
    done
    log_success "auditd.conf 配置完成"

    # 8. 加载规则
    log_info "加载 auditd 规则..."
    augenrules --load
    log_success "规则已加载"

    # 9. 启动/重启 auditd
    systemctl enable auditd
    systemctl restart auditd
    log_success "auditd 服务已启动"

    # 10. 输出安装成功信息
    echo ""
    log_success "Phase 33: auditd Docker 审计规则安装完成"
    echo ""
    log_info "规则文件: $RULES_FILE"
    log_info "查询命令: sudo ausearch -k docker-cmd -ts recent -i"
    echo ""
    log_info "建议运行 'sudo bash $0 verify' 验证安装"
}

# ============================================
# 子命令：verify — 验证 auditd 规则
# ============================================
cmd_verify() {
    local all_ok=true

    log_info "Phase 33: 验证 auditd Docker 审计规则 (平台: $PLATFORM)..."
    echo ""

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不支持 auditd，跳过验证"
        return 0
    fi

    # 2. 检查规则文件存在
    if [ ! -f "$RULES_FILE" ]; then
        log_error "规则文件不存在: $RULES_FILE"
        return 1
    fi
    log_success "规则文件存在: $RULES_FILE"

    # 3. 检查规则文件权限
    local perms owner group
    perms="$(stat -c '%a' "$RULES_FILE")"
    owner="$(stat -c '%U' "$RULES_FILE")"
    group="$(stat -c '%G' "$RULES_FILE")"

    if [[ "$perms" == "640" && "$owner" == "root" && "$group" == "root" ]]; then
        log_success "文件权限正确: 0640 root:root"
    else
        log_error "文件权限错误: $perms $owner:$group (期望: 0640 root:root)"
        all_ok=false
    fi

    # 4. 检查 auditd 服务运行
    if systemctl is-active --quiet auditd; then
        log_success "auditd 服务运行中"
    else
        log_error "auditd 服务未运行"
        all_ok=false
    fi

    # 5. 检查规则已加载
    if auditctl -l 2>/dev/null | grep -q "docker-cmd"; then
        log_success "docker-cmd 规则已加载"
    else
        log_error "docker-cmd 规则未加载"
        all_ok=false
    fi

    # 6. 检查 auditd.conf 参数
    local conf_params=(
        "log_group = root"
        "max_log_file = 50"
        "max_log_file_action = ROTATE"
        "num_logs = 30"
        "log_format = ENRICHED"
    )

    for param in "${conf_params[@]}"; do
        if grep -q "$param" "$AUDITD_CONF" 2>/dev/null; then
            log_success "auditd.conf: $param"
        else
            log_error "auditd.conf 缺少: $param"
            all_ok=false
        fi
    done

    # 7. 检查日志目录权限
    if [ -d /var/log/audit/ ]; then
        local log_perms log_owner log_group_name
        log_perms="$(stat -c '%a' /var/log/audit/)"
        log_owner="$(stat -c '%U' /var/log/audit/)"
        log_group_name="$(stat -c '%G' /var/log/audit/)"

        if [[ "$log_owner" == "root" && "$log_group_name" == "root" ]]; then
            log_success "日志目录属主正确: root:root"
        else
            log_error "日志目录属主错误: $log_owner:$log_group_name (期望: root:root)"
            all_ok=false
        fi

        if [ -f /var/log/audit/audit.log ]; then
            local file_perms file_owner file_group
            file_perms="$(stat -c '%a' /var/log/audit/audit.log)"
            file_owner="$(stat -c '%U' /var/log/audit/audit.log)"
            file_group="$(stat -c '%G' /var/log/audit/audit.log)"

            if [[ "$file_owner" == "root" && "$file_group" == "root" ]]; then
                log_success "日志文件属主正确: root:root ($file_perms)"
            else
                log_error "日志文件属主错误: $file_owner:$file_group (期望: root:root)"
                all_ok=false
            fi
        fi
    else
        log_warn "日志目录不存在: /var/log/audit/（auditd 可能未运行过）"
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
# 子命令：uninstall — 卸载 auditd 规则
# ============================================
cmd_uninstall() {
    log_info "Phase 33: 卸载 auditd Docker 审计规则..."

    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不支持 auditd，无需卸载"
        return 0
    fi

    if [ -f "$RULES_FILE" ]; then
        rm -f "$RULES_FILE"
        log_success "已删除规则文件: $RULES_FILE"
    else
        log_warn "规则文件不存在: $RULES_FILE"
    fi

    # 重新加载规则（移除已删除的规则）
    augenrules --load 2>/dev/null || true
    log_success "Phase 33: auditd Docker 审计规则卸载完成"
}

# ============================================
# 用法说明
# ============================================
usage() {
    cat <<EOF
用法: sudo $(basename "$0") <命令>

命令:
  install    安装 auditd Docker 审计规则（内核级监控 docker 命令）
  verify     验证 auditd Docker 审计规则是否正确
  uninstall  卸载 auditd Docker 审计规则
  help       显示此帮助信息

审计规则:
  监控 /usr/bin/docker 的所有执行（AUDIT-01）
  包含普通用户（auid>=1000）和 jenkins 系统用户规则
  审计日志保护: root:root 0600（AUDIT-02）

日志配置 (D-01):
  max_log_file = 50MB, num_logs = 30, log_format = ENRICHED

查询命令:
  sudo ausearch -k docker-cmd -ts recent -i

规则文件: $RULES_FILE

平台兼容:
  macOS:  跳过安装（不支持 auditd）
  Linux:  安装完整 auditd 规则
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
