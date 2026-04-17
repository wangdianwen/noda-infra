#!/bin/bash
set -euo pipefail

# ============================================
# Phase 31: 一站式权限应用脚本
# ============================================
# 功能：文件权限锁定 + Docker socket 属组 + Git post-merge hook + 验证
# 子命令：apply, verify, hook, help
# 用途：生产服务器运行此脚本即可完成所有权限配置
# 要求：需要 root 权限执行（sudo bash scripts/apply-file-permissions.sh apply）
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCKER_OVERRIDE_DIR="/etc/systemd/system/docker.service.d"
DOCKER_OVERRIDE_CONF="$DOCKER_OVERRIDE_DIR/socket-permissions.conf"

# D-03: 最小范围锁定
LOCKED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
    "$PROJECT_ROOT/scripts/pipeline-stages.sh"
    "$PROJECT_ROOT/scripts/manage-containers.sh"
)

source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# macOS/Linux stat 兼容
# ============================================
stat_perms() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%Lp:%Su:%Sg' "$file"
    else
        stat -c '%a:%U:%G' "$file"
    fi
}

stat_group() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%Sg' "$file"
    else
        stat -c '%G' "$file"
    fi
}

stat_mode() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f '%Lp' "$file"
    else
        stat -c '%a' "$file"
    fi
}

# ============================================
# 子命令：apply — 执行所有权限配置
# ============================================
cmd_apply() {
    log_info "Phase 31: 应用权限配置..."

    # 1. 创建 /opt/noda/ 目录（manage-containers.sh 需要）
    log_info "创建 /opt/noda/ 目录..."
    sudo mkdir -p /opt/noda
    sudo chown root:jenkins /opt/noda
    sudo chmod 770 /opt/noda
    log_success "/opt/noda/ 目录已配置 (root:jenkins 770)"

    # 2. 文件权限锁定（D-03）
    log_info "锁定部署脚本权限..."
    for script in "${LOCKED_SCRIPTS[@]}"; do
        if [ -f "$script" ]; then
            sudo chown root:jenkins "$script"
            sudo chmod 750 "$script"
            log_success "已锁定: $script (750 root:jenkins)"
        else
            log_warn "文件不存在，跳过: $script"
        fi
    done

    # 3. systemd override（PERM-02）
    log_info "创建 Docker socket systemd override..."
    sudo mkdir -p "$DOCKER_OVERRIDE_DIR"
    sudo tee "$DOCKER_OVERRIDE_CONF" > /dev/null <<'EOF'
[Service]
ExecStartPost=/bin/sh -c 'chown root:jenkins /var/run/docker.sock && chmod 660 /var/run/docker.sock'
EOF
    log_success "systemd override 已写入: $DOCKER_OVERRIDE_CONF"

    # 4. daemon-reload
    if command -v systemctl >/dev/null 2>&1; then
        sudo systemctl daemon-reload 2>/dev/null || true
        log_success "systemd daemon-reload 完成"
    else
        log_warn "systemctl 不可用（非 Linux 环境），跳过 daemon-reload"
    fi

    # 5. 立即应用 socket 权限
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker 2>/dev/null; then
        log_info "重启 Docker 服务以应用 socket 权限..."
        sudo systemctl restart docker
        log_success "Docker 服务已重启"
    else
        log_warn "Docker 服务未运行或 systemctl 不可用，跳过重启"
    fi

    # 6. 从 docker 组移除 jenkins（如果存在）
    log_info "从 docker 组移除 jenkins 用户..."
    sudo gpasswd -d jenkins docker 2>/dev/null || true
    log_success "jenkins 用户已从 docker 组移除（如存在）"

    # 7. 重启 Jenkins（组变更需要进程重启）
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet jenkins 2>/dev/null; then
        log_info "重启 Jenkins 服务以应用组变更..."
        sudo systemctl restart jenkins
        log_success "Jenkins 服务已重启"
    else
        log_warn "Jenkins 服务未运行或 systemctl 不可用，跳过重启"
    fi

    # 8. 创建 post-merge hook
    cmd_hook

    log_success "Phase 31: 权限配置完成"
    echo ""
    log_info "建议运行 'sudo bash $0 verify' 验证所有配置"
}

# ============================================
# 子命令：verify — 验证所有权限配置
# ============================================
cmd_verify() {
    local all_ok=true

    log_info "Phase 31: 验证权限配置..."
    echo ""

    # 1. 验证 socket 属组
    if [ -S /var/run/docker.sock ]; then
        local socket_group
        socket_group=$(stat_group /var/run/docker.sock)
        if [ "$socket_group" = "jenkins" ]; then
            log_success "Docker socket 属组: jenkins"
        else
            log_error "Docker socket 属组: $socket_group (期望: jenkins)"
            all_ok=false
        fi
    else
        log_warn "Docker socket 不存在（非 Linux 或 Docker 未运行），跳过"
    fi

    # 2. 验证 socket 权限
    if [ -S /var/run/docker.sock ]; then
        local socket_mode
        socket_mode=$(stat_mode /var/run/docker.sock)
        if [ "$socket_mode" = "660" ]; then
            log_success "Docker socket 权限: 660"
        else
            log_error "Docker socket 权限: $socket_mode (期望: 660)"
            all_ok=false
        fi
    fi

    # 3. 验证 systemd override
    if [ -f "$DOCKER_OVERRIDE_CONF" ]; then
        log_success "systemd override 文件存在: $DOCKER_OVERRIDE_CONF"
    else
        if [[ "$(uname)" == "Darwin" ]]; then
            log_warn "systemd override 不存在（macOS 环境，正常）"
        else
            log_error "systemd override 文件不存在: $DOCKER_OVERRIDE_CONF"
            all_ok=false
        fi
    fi

    # 4. 验证锁定脚本权限
    for script in "${LOCKED_SCRIPTS[@]}"; do
        if [ -f "$script" ]; then
            local perms
            perms=$(stat_perms "$script")
            if [ "$perms" = "750:root:jenkins" ]; then
                log_success "脚本权限正确: $script (750:root:jenkins)"
            else
                log_error "脚本权限错误: $script (当前: $perms, 期望: 750:root:jenkins)"
                all_ok=false
            fi
        else
            log_warn "文件不存在: $script"
        fi
    done

    # 5. 验证 post-merge hook
    local hook_file="$PROJECT_ROOT/.git/hooks/post-merge"
    if [ -f "$hook_file" ] && [ -x "$hook_file" ]; then
        log_success "post-merge hook 存在且可执行: $hook_file"
    else
        log_error "post-merge hook 不存在或不可执行: $hook_file"
        all_ok=false
    fi

    # 6. 验证 jenkins 用户可执行 docker
    if command -v docker >/dev/null 2>&1 && id jenkins >/dev/null 2>&1; then
        if sudo -u jenkins docker info >/dev/null 2>&1; then
            log_success "jenkins 用户可以执行 docker 命令"
        else
            log_error "jenkins 用户无法执行 docker 命令"
            all_ok=false
        fi
    else
        log_warn "docker 或 jenkins 用户不存在（非生产环境），跳过"
    fi

    # 7. 验证 /opt/noda/ 目录权限
    if [ -d /opt/noda ]; then
        local noda_perms
        noda_perms=$(stat_perms /opt/noda)
        if [ "$noda_perms" = "770:root:jenkins" ]; then
            log_success "/opt/noda/ 目录权限: 770:root:jenkins"
        else
            log_error "/opt/noda/ 目录权限: $noda_perms (期望: 770:root:jenkins)"
            all_ok=false
        fi
    else
        log_warn "/opt/noda/ 目录不存在"
    fi

    echo ""
    if $all_ok; then
        log_success "所有权限配置验证通过"
    else
        log_error "部分权限配置验证失败，请检查上述错误"
        return 1
    fi
}

# ============================================
# 子命令：hook — 创建 Git post-merge hook
# ============================================
cmd_hook() {
    local hook_file="$PROJECT_ROOT/.git/hooks/post-merge"

    log_info "创建 Git post-merge hook..."

    # 确保 .git/hooks/ 目录存在
    mkdir -p "$(dirname "$hook_file")"

    # 写入 hook 内容
    cat > "$hook_file" <<'HOOKEOF'
#!/bin/bash
# .git/hooks/post-merge — git pull 后恢复部署脚本锁定权限
# 由 apply-file-permissions.sh 创建，不在版本控制中

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LOCKED_SCRIPTS=(
    "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
    "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
    "$PROJECT_ROOT/scripts/pipeline-stages.sh"
    "$PROJECT_ROOT/scripts/manage-containers.sh"
)

for script in "${LOCKED_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
        chown root:jenkins "$script" 2>/dev/null || \
            sudo chown root:jenkins "$script" 2>/dev/null || true
        chmod 750 "$script" 2>/dev/null || \
            sudo chmod 750 "$script" 2>/dev/null || true
    fi
done
HOOKEOF

    chmod +x "$hook_file"
    log_success "post-merge hook 已创建: $hook_file"
}

# ============================================
# 用法说明
# ============================================
usage() {
    cat <<EOF
用法: $(basename "$0") <命令>

命令:
  apply   应用所有权限配置（文件锁定 + socket 属组 + hook）
  verify  验证所有权限配置是否正确
  hook    仅创建/更新 Git post-merge hook
  help    显示此帮助信息

锁定脚本列表（D-03 最小范围）:
  scripts/deploy/deploy-apps-prod.sh
  scripts/deploy/deploy-infrastructure-prod.sh
  scripts/pipeline-stages.sh
  scripts/manage-containers.sh
EOF
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
    apply)
        cmd_apply
        ;;
    verify)
        cmd_verify
        ;;
    hook)
        cmd_hook
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
