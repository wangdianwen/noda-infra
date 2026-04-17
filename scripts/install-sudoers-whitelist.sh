#!/bin/bash
set -euo pipefail

# ============================================
# Phase 32: sudoers 白名单安装/验证/卸载脚本
# ============================================
# 功能：安装 Docker 只读命令的 sudoers 白名单规则
# 子命令：install, verify, uninstall, help
# 要求：需要 root 权限执行
# 兼容：macOS + Linux 双平台
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SUDOERS_FILE="/etc/sudoers.d/noda-docker-readonly"
SUDOERS_BACKUP="/opt/noda/pre-phase32-sudoers-backup.txt"

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
# 子命令：install — 安装 sudoers 白名单规则
# ============================================
cmd_install() {
    log_info "Phase 32: 安装 sudoers 白名单规则 (平台: $PLATFORM)..."

    # 1. 平台检查
    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 sudoers 白名单（Docker Desktop 无 socket 权限问题）"
        return 0
    fi

    # 2. 确保 /etc/sudoers.d/ 目录存在
    if [ ! -d /etc/sudoers.d ]; then
        log_info "创建 /etc/sudoers.d/ 目录..."
        mkdir -p /etc/sudoers.d
    fi

    # 3. 备份当前状态
    if [ -f "$SUDOERS_FILE" ]; then
        log_info "备份现有 sudoers 规则到 $SUDOERS_BACKUP..."
        mkdir -p "$(dirname "$SUDOERS_BACKUP")"
        cp "$SUDOERS_FILE" "$SUDOERS_BACKUP"
        log_success "备份完成"
    else
        mkdir -p "$(dirname "$SUDOERS_BACKUP")"
        echo "未找到已有的 sudoers 规则文件（首次安装）" > "$SUDOERS_BACKUP"
    fi

    # 4. 写入 sudoers 规则文件
    log_info "写入 sudoers 规则文件: $SUDOERS_FILE..."
    tee "$SUDOERS_FILE" > /dev/null <<'EOF'
# Noda Docker Read-Only Whitelist (Phase 32)
# 允许 admin/sudo 组用户通过 sudo 执行只读 docker 命令
# 白名单: ps, logs, inspect, stats, top (per D-05, BREAK-01)
# 黑名单: run, rm, exec, compose (per D-05, BREAK-02)

# 命令别名：只读 docker 命令
Cmnd_Alias DOCKER_READ_ONLY = \
    /usr/bin/docker ps, \
    /usr/bin/docker ps *, \
    /usr/bin/docker logs, \
    /usr/bin/docker logs *, \
    /usr/bin/docker inspect, \
    /usr/bin/docker inspect *, \
    /usr/bin/docker stats, \
    /usr/bin/docker stats *, \
    /usr/bin/docker top, \
    /usr/bin/docker top *

# 命令别名：写入 docker 命令（显式拒绝）
Cmnd_Alias DOCKER_WRITE = \
    /usr/bin/docker run, \
    /usr/bin/docker run *, \
    /usr/bin/docker rm, \
    /usr/bin/docker rm *, \
    /usr/bin/docker exec, \
    /usr/bin/docker exec *, \
    /usr/bin/docker compose *, \
    /usr/bin/docker stop, \
    /usr/bin/docker stop *, \
    /usr/bin/docker restart, \
    /usr/bin/docker restart *, \
    /usr/bin/docker kill, \
    /usr/bin/docker kill *, \
    /usr/bin/docker cp, \
    /usr/bin/docker cp *, \
    /usr/bin/docker create, \
    /usr/bin/docker create *, \
    /usr/bin/docker build, \
    /usr/bin/docker build *, \
    /usr/bin/docker push, \
    /usr/bin/docker push *, \
    /usr/bin/docker rmi, \
    /usr/bin/docker rmi *, \
    /usr/bin/docker network *, \
    /usr/bin/docker volume *, \
    /usr/bin/docker system *, \
    /usr/bin/docker container *, \
    /usr/bin/docker image *, \
    /usr/bin/docker swarm *, \
    /usr/bin/docker login, \
    /usr/bin/docker login *, \
    /usr/bin/docker pull, \
    /usr/bin/docker pull *

# 规则：写入命令全部拒绝
%sudo ALL = !DOCKER_WRITE

# 规则：只读命令允许（无需密码，因为只读无害）
%sudo ALL = NOPASSWD: DOCKER_READ_ONLY
EOF

    # 5. 验证语法
    log_info "验证 sudoers 语法..."
    if ! visudo -cf "$SUDOERS_FILE"; then
        log_error "sudoers 语法验证失败，删除无效文件"
        rm -f "$SUDOERS_FILE"
        exit 1
    fi
    log_success "sudoers 语法验证通过"

    # 6. 设置文件权限
    chmod 0440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    log_success "文件权限已设置: 0440 root:root"

    # 7. 输出安装成功信息
    echo ""
    log_success "Phase 32: sudoers 白名单规则安装完成"
    echo ""
    log_info "白名单命令: docker ps, logs, inspect, stats, top"
    log_info "黑名单命令: docker run, rm, exec, compose, stop, restart, kill, ..."
    log_info "规则文件: $SUDOERS_FILE"
    log_info "备份文件: $SUDOERS_BACKUP"
    echo ""
    log_info "建议运行 'sudo bash $0 verify' 验证规则"
}

# ============================================
# 子命令：verify — 验证 sudoers 规则
# ============================================
cmd_verify() {
    local all_ok=true

    log_info "Phase 32: 验证 sudoers 白名单规则 (平台: $PLATFORM)..."
    echo ""

    # 1. 检查文件存在
    if [ ! -f "$SUDOERS_FILE" ]; then
        log_error "sudoers 文件不存在: $SUDOERS_FILE"
        return 1
    fi
    log_success "sudoers 文件存在: $SUDOERS_FILE"

    # 2. 检查文件权限
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

    # 3. 语法验证
    if ! visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
        log_error "sudoers 语法验证失败"
        all_ok=false
    else
        log_success "sudoers 语法验证通过"
    fi

    # 4. 检查白名单包含 5 个只读命令
    local read_only_cmds=("docker ps" "docker logs" "docker inspect" "docker stats" "docker top")
    for cmd in "${read_only_cmds[@]}"; do
        if grep -q "$cmd" "$SUDOERS_FILE"; then
            log_success "白名单包含: $cmd"
        else
            log_error "白名单缺少: $cmd"
            all_ok=false
        fi
    done

    # 5. 检查黑名单包含 docker exec (D-04)
    if grep -q "docker exec" "$SUDOERS_FILE"; then
        log_success "黑名单包含: docker exec (D-04)"
    else
        log_error "黑名单缺少: docker exec (D-04)"
        all_ok=false
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
# 子命令：uninstall — 卸载 sudoers 规则
# ============================================
cmd_uninstall() {
    log_info "Phase 32: 卸载 sudoers 白名单规则..."

    if [[ "$PLATFORM" == "macos" ]]; then
        log_warn "macOS 不需要 sudoers 白名单，无需卸载"
        return 0
    fi

    if [ ! -f "$SUDOERS_FILE" ]; then
        log_warn "sudoers 文件不存在: $SUDOERS_FILE"
        return 0
    fi

    rm -f "$SUDOERS_FILE"
    log_success "已删除 sudoers 规则文件: $SUDOERS_FILE"
    log_success "Phase 32: sudoers 白名单规则卸载完成"
}

# ============================================
# 用法说明
# ============================================
usage() {
    cat <<EOF
用法: sudo $(basename "$0") <命令>

命令:
  install    安装 sudoers 白名单规则（只读 docker 命令）
  verify     验证 sudoers 白名单规则是否正确
  uninstall  卸载 sudoers 白名单规则
  help       显示此帮助信息

白名单命令（BREAK-01）:
  docker ps, docker logs, docker inspect, docker stats, docker top

黑名单命令（BREAK-02）:
  docker run, docker rm, docker exec, docker compose, docker stop,
  docker restart, docker kill, docker cp, docker create, docker build,
  docker push, docker rmi, docker network, docker volume, docker system,
  docker container, docker image, docker swarm, docker login, docker pull

规则文件: $SUDOERS_FILE
备份文件: $SUDOERS_BACKUP

平台兼容:
  macOS:  跳过安装（Docker Desktop 无需 sudoers 白名单）
  Linux:  安装完整 sudoers 规则到 /etc/sudoers.d/
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
