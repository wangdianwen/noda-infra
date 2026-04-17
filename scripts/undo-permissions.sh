#!/bin/bash
set -euo pipefail

# ============================================
# Phase 31 最小 Undo 脚本
# ============================================
# 功能：备份当前权限状态 + 回滚 Phase 31 权限变更
# 用途：权限收敛前的安全网，确保可恢复到变更前状态
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
# 常量
# ============================================
BACKUP_FILE="/opt/noda/pre-phase31-permissions-backup.txt"

# D-03: 最小范围锁定脚本列表
LOCKED_SCRIPTS=(
  "$PROJECT_ROOT/scripts/deploy/deploy-apps-prod.sh"
  "$PROJECT_ROOT/scripts/deploy/deploy-infrastructure-prod.sh"
  "$PROJECT_ROOT/scripts/pipeline-stages.sh"
  "$PROJECT_ROOT/scripts/manage-containers.sh"
)

# ============================================
# get_stat_info() — 跨平台获取文件权限信息
# ============================================
# macOS stat 不支持 -c 格式，需要条件判断
# 参数：$1 = 文件路径
# 返回：权限字符串（格式：mode:owner:group）
get_stat_info() {
  local file="$1"
  if [[ "$(uname)" == "Darwin" ]]; then
    local mode owner group
    mode=$(stat -f '%Lp' "$file" 2>/dev/null || echo "unknown")
    owner=$(stat -f '%Su' "$file" 2>/dev/null || echo "unknown")
    group=$(stat -f '%Sg' "$file" 2>/dev/null || echo "unknown")
    echo "${mode}:${owner}:${group}"
  else
    stat -c '%a:%U:%G' "$file" 2>/dev/null || echo "unknown:unknown:unknown"
  fi
}

# ============================================
# get_socket_group() — 获取 socket 属组
# ============================================
# macOS 无 docker.sock，返回 unknown
get_socket_group() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "unknown"
  else
    stat -c '%G' /var/run/docker.sock 2>/dev/null || echo "unknown"
  fi
}

# ============================================
# get_socket_mode() — 获取 socket 权限模式
# ============================================
get_socket_mode() {
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "unknown"
  else
    stat -c '%a' /var/run/docker.sock 2>/dev/null || echo "unknown"
  fi
}

# ============================================
# backup_current_state() — 备份当前权限状态
# ============================================
# 写入 BACKUP_FILE，包含 socket 属组、脚本权限、systemd override、jenkins 组信息
# 文件权限 600（仅 root 可读，T-31-02 缓解）
backup_current_state() {
  log_info "=========================================="
  log_info "备份当前权限状态 (平台: $PLATFORM)"
  log_info "=========================================="

  sudo mkdir -p "$(dirname "$BACKUP_FILE")"

  {
    echo "# Phase 31 权限备份 - $(date -Iseconds)"
    echo ""
    echo "# Docker socket"
    echo "SOCKET_GROUP=$(get_socket_group)"
    echo "SOCKET_MODE=$(get_socket_mode)"
    echo ""
    echo "# 锁定脚本权限"
    for script in "${LOCKED_SCRIPTS[@]}"; do
      if [ -f "$script" ]; then
        echo "FILE_PERMS=$(get_stat_info "$script") FILE=$script"
      else
        echo "# 文件不存在: $script"
      fi
    done
    echo ""
    echo "# systemd docker override"
    if [[ "$PLATFORM" == "linux" ]]; then
      local override_dir="/etc/systemd/system/docker.service.d"
      if [ -d "$override_dir" ]; then
        sudo cat "$override_dir"/*.conf 2>/dev/null || echo "无 override 文件"
      else
        echo "无 override 目录"
      fi
    else
      echo "N/A (macOS 环境，无 systemd)"
    fi
    echo ""
    echo "# jenkins 组信息"
    if [[ "$PLATFORM" == "linux" ]]; then
      if id jenkins >/dev/null 2>&1; then
        groups jenkins 2>/dev/null || echo "jenkins 用户存在但无法获取组信息"
      else
        echo "jenkins 用户不存在"
      fi
    else
      echo "N/A (macOS 环境，无 jenkins 用户)"
    fi
  } | sudo tee "$BACKUP_FILE" > /dev/null

  sudo chmod 600 "$BACKUP_FILE"

  log_success "权限状态已备份到: $BACKUP_FILE"
  log_info "备份内容:"
  sudo cat "$BACKUP_FILE"
}

# ============================================
# undo_permissions() — 从备份恢复权限状态
# ============================================
# 恢复 socket 为 root:docker、移除 systemd override、恢复脚本权限、jenkins 加入 docker 组
undo_permissions() {
  log_info "=========================================="
  log_info "回滚 Phase 31 权限变更 (平台: $PLATFORM)"
  log_info "=========================================="

  # 检查备份文件
  if [ ! -f "$BACKUP_FILE" ]; then
    log_error "备份文件不存在: $BACKUP_FILE"
    log_info "请先运行: bash $0 backup"
    exit 1
  fi

  log_info "使用的备份文件:"
  sudo cat "$BACKUP_FILE"
  echo ""

  # 步骤 1/6: 恢复 socket 属组为 root:docker
  log_info "步骤 1/6: 恢复 Docker socket 属组为 root:docker"
  if [[ "$PLATFORM" == "linux" ]]; then
    sudo chown root:docker /var/run/docker.sock
    sudo chmod 660 /var/run/docker.sock
    log_success "socket 属组已恢复"
  else
    log_warn "macOS 环境：跳过 socket 属组恢复（Docker Desktop 管理）"
  fi

  # 步骤 2/6: 移除 systemd override
  log_info "步骤 2/6: 移除 Docker socket 权限 systemd override"
  if [[ "$PLATFORM" == "linux" ]]; then
    sudo rm -f /etc/systemd/system/docker.service.d/socket-permissions.conf
    sudo systemctl daemon-reload
    log_success "systemd override 已移除"
  else
    log_warn "macOS 环境：跳过 systemd override 移除（无 systemd）"
  fi

  # 步骤 3/6: 重启 Docker（使 override 生效）
  log_info "步骤 3/6: 重启 Docker 服务"
  if [[ "$PLATFORM" == "linux" ]]; then
    sudo systemctl restart docker
    log_success "Docker 服务已重启"
  else
    log_info "macOS 环境：请手动重启 Docker Desktop 以确保配置生效"
  fi

  # 步骤 4/6: 恢复脚本权限为默认值
  log_info "步骤 4/6: 恢复脚本权限为 755"
  for script in "${LOCKED_SCRIPTS[@]}"; do
    if [ -f "$script" ]; then
      sudo chmod 755 "$script"
      if [[ "$PLATFORM" == "macos" ]]; then
        sudo chown "$(whoami):staff" "$script"
      else
        sudo chown "$(whoami):$(whoami)" "$script"
      fi
      log_success "已恢复: $script"
    else
      log_warn "文件不存在，跳过: $script"
    fi
  done

  # 步骤 5/6: 将 jenkins 重新加入 docker 组
  log_info "步骤 5/6: 将 jenkins 重新加入 docker 组"
  if [[ "$PLATFORM" == "linux" ]]; then
    sudo usermod -aG docker jenkins
    log_success "jenkins 用户已重新加入 docker 组"
  else
    log_warn "macOS 环境：跳过 jenkins 组操作（无 jenkins 用户）"
  fi

  # 步骤 6/6: 重启 Jenkins（使组变更生效）
  log_info "步骤 6/6: 重启 Jenkins 服务（使组变更生效）"
  if [[ "$PLATFORM" == "macos" ]]; then
    brew services restart jenkins 2>/dev/null || log_warn "macOS: Jenkins 未通过 Homebrew 管理"
  else
    sudo systemctl restart jenkins
    log_success "Jenkins 服务已重启"
  fi

  log_success "=========================================="
  log_success "Phase 31 权限变更已回滚"
  log_success "=========================================="
  if [[ "$PLATFORM" == "linux" ]]; then
    log_info "验证命令:"
    log_info "  sudo -u jenkins docker ps"
    log_info "  ls -la /var/run/docker.sock"
  else
    log_info "macOS 环境：Docker Desktop 自动管理 socket 权限"
  fi
}

# ============================================
# usage() — 显示帮助信息
# ============================================
usage() {
  cat <<'EOF'
Phase 31 最小 Undo 脚本

用法: undo-permissions.sh <命令>

命令:
  backup  备份当前权限状态（在执行权限修改前运行）
  undo    从备份恢复权限状态（回滚 Phase 31 所有变更）
  help    显示此帮助信息

备份文件: /opt/noda/pre-phase31-permissions-backup.txt（权限 600，仅 root 可读）

回滚操作（Linux）:
  1. 恢复 Docker socket 属组为 root:docker (660)
  2. 移除 systemd socket 权限 override
  3. 重启 Docker 服务
  4. 恢复脚本权限为 755
  5. 将 jenkins 重新加入 docker 组
  6. 重启 Jenkins 服务

平台差异:
  macOS: 步骤 1-3/5 跳过（Docker Desktop 管理 socket，无 jenkins 用户）
  macOS: 步骤 4 通用，步骤 6 使用 brew services restart jenkins
EOF
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
  backup)  backup_current_state ;;
  undo)    undo_permissions ;;
  help)    usage ;;
  *)       usage && exit 1 ;;
esac
