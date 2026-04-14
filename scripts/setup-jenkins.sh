#!/bin/bash
set -euo pipefail

# ============================================
# Jenkins 生命周期管理脚本
# ============================================
# 功能：安装、卸载、状态检查、密码获取、重启、升级、密码重置
# 用途：单一入口管理 Jenkins 在宿主机上的所有运维操作
# ============================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/log.sh"

# ============================================
# 常量
# ============================================
JENKINS_PORT=8888
JENKINS_HOME="/var/lib/jenkins"
JENKINS_LOG="/var/log/jenkins"
JENKINS_OVERRIDE_DIR="/etc/systemd/system/jenkins.service.d"
JENKINS_OVERRIDE_CONF="$JENKINS_OVERRIDE_DIR/override.conf"
GROOVY_SRC_DIR="$SCRIPT_DIR/jenkins/init.groovy.d"
ADMIN_ENV_TEMPLATE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env.example"
ADMIN_ENV_FILE="$SCRIPT_DIR/jenkins/config/jenkins-admin.env"

# ============================================
# usage() — 显示帮助信息
# ============================================
usage() {
  cat <<'EOF'
Jenkins 生命周期管理脚本

用法: setup-jenkins.sh <命令> [参数]

命令:
  install         安装 Java 21 + Jenkins LTS + 配置 Docker 权限 + 启动服务
  uninstall       完全卸载 Jenkins 及所有残留文件
  status          检查 Jenkins 运行状态、端口、Docker 权限
  show-password   显示初始管理员密码
  restart         重启 Jenkins 服务
  upgrade         升级 Jenkins 到最新 LTS
  reset-password <新密码>  重置管理员密码

示例:
  setup-jenkins.sh install
  setup-jenkins.sh status
  setup-jenkins.sh show-password
  setup-jenkins.sh reset-password my-new-password
EOF
}

# ============================================
# wait_for_jenkins() — 等待 Jenkins HTTP 端口就绪
# ============================================
# 参数：无
# 返回：0=就绪，1=超时
wait_for_jenkins() {
  local port="${JENKINS_PORT:-8888}"
  local max_wait=120
  local waited=0

  log_info "等待 Jenkins 启动（端口 ${port}）..."

  while [ "$waited" -lt "$max_wait" ]; do
    if curl -sf "http://localhost:${port}/login" > /dev/null 2>&1; then
      log_success "Jenkins 已就绪（耗时 ${waited}s）"
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
    log_info "已等待 ${waited}s / ${max_wait}s..."
  done

  log_error "Jenkins 启动超时（${max_wait}s）"
  return 1
}

# ============================================
# cmd_install() — 安装 Java 21 + Jenkins LTS + Docker 权限
# ============================================
cmd_install() {
  log_info "=========================================="
  log_info "Jenkins 安装开始"
  log_info "=========================================="

  # 步骤 1/10: 检查是否已安装
  log_info "步骤 1/10: 检查 Jenkins 安装状态"
  if dpkg -l jenkins > /dev/null 2>&1; then
    log_error "Jenkins 已安装，请先执行 uninstall 或使用 upgrade 升级"
    exit 1
  fi
  log_success "Jenkins 未安装，继续安装"

  # 步骤 2/10: 安装 Java 21
  log_info "步骤 2/10: 安装 Java 21"
  sudo apt update
  sudo apt install -y fontconfig openjdk-21-jre

  # 步骤 3/10: 验证 Java
  log_info "步骤 3/10: 验证 Java 安装"
  if ! java -version 2>&1; then
    log_error "Java 安装失败"
    exit 1
  fi
  log_success "Java 安装验证通过"

  # 步骤 4/10: 添加 Jenkins apt 源
  log_info "步骤 4/10: 添加 Jenkins apt 源"
  sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
    https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
  echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
    https://pkg.jenkins.io/debian-stable binary/ | \
    sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
  sudo apt update
  log_success "Jenkins apt 源添加成功"

  # 步骤 5/10: 安装 Jenkins
  log_info "步骤 5/10: 安装 Jenkins"
  sudo apt install -y jenkins
  log_success "Jenkins 包安装完成"

  # 步骤 6/10: 配置端口 8888 (systemd override)
  log_info "步骤 6/10: 配置端口 ${JENKINS_PORT} (systemd override)"
  sudo mkdir -p "$JENKINS_OVERRIDE_DIR"
  sudo tee "$JENKINS_OVERRIDE_CONF" > /dev/null <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
EOF
  sudo systemctl daemon-reload
  log_success "端口配置完成（${JENKINS_PORT}）"

  # 步骤 7/10: 写入 init.groovy.d 脚本
  log_info "步骤 7/10: 写入 init.groovy.d 脚本"
  if [ -d "$GROOVY_SRC_DIR" ] && ls "$GROOVY_SRC_DIR"/*.groovy > /dev/null 2>&1; then
    sudo mkdir -p "$JENKINS_HOME/init.groovy.d"
    sudo cp "$GROOVY_SRC_DIR"/*.groovy "$JENKINS_HOME/init.groovy.d/"
    sudo chown -R jenkins:jenkins "$JENKINS_HOME/init.groovy.d"
    log_success "init.groovy.d 脚本已写入"
  else
    log_info "无 init.groovy.d 脚本，跳过首次自动化配置"
  fi

  # 步骤 7.5: 写入管理员凭据
  log_info "步骤 7.5/10: 写入管理员凭据"
  if [ ! -f "$JENKINS_HOME/.admin.env" ] && [ -f "$ADMIN_ENV_FILE" ]; then
    sudo cp "$ADMIN_ENV_FILE" "$JENKINS_HOME/.admin.env"
    sudo chown jenkins:jenkins "$JENKINS_HOME/.admin.env"
    sudo chmod 600 "$JENKINS_HOME/.admin.env"
    log_success "管理员凭据已写入（权限 600）"
  elif [ -f "$JENKINS_HOME/.admin.env" ]; then
    log_info "管理员凭据已存在，跳过"
  else
    log_info "无管理员凭据文件（${ADMIN_ENV_FILE}），跳过"
  fi

  # 步骤 8/10: Docker 权限
  log_info "步骤 8/10: 配置 Docker 权限"
  sudo usermod -aG docker jenkins
  log_success "jenkins 用户已加入 docker 组"

  # 步骤 9/10: 启动 Jenkins
  log_info "步骤 9/10: 启动 Jenkins"
  sudo systemctl enable jenkins
  sudo systemctl start jenkins
  log_info "Jenkins 服务已启动"

  # 步骤 9.5: 等待 Jenkins 就绪
  log_info "步骤 9.5/10: 等待 Jenkins 就绪"
  if ! wait_for_jenkins; then
    log_error "Jenkins 启动失败，请检查日志: sudo journalctl -u jenkins"
    exit 1
  fi

  # 步骤 10/10: 清理 init.groovy.d
  log_info "步骤 10/10: 清理 init.groovy.d 脚本"
  sudo rm -rf "$JENKINS_HOME/init.groovy.d"
  log_success "init.groovy.d 脚本已清理"

  # 安装完成
  log_success "=========================================="
  log_success "Jenkins 安装完成！"
  log_success "=========================================="
  log_info "访问地址: http://localhost:${JENKINS_PORT}"
  log_info "获取初始密码: bash $0 show-password"
  log_success "=========================================="
}

# ============================================
# cmd_uninstall() — 完全卸载 Jenkins
# ============================================
cmd_uninstall() {
  log_info "=========================================="
  log_info "Jenkins 卸载开始"
  log_info "=========================================="

  # 步骤 1/13: 停止服务
  log_info "步骤 1/13: 停止 Jenkins 服务"
  sudo systemctl stop jenkins 2>/dev/null || true

  # 步骤 2/13: 禁用服务
  log_info "步骤 2/13: 禁用 Jenkins 服务"
  sudo systemctl disable jenkins 2>/dev/null || true

  # 步骤 3/13: 卸载包
  log_info "步骤 3/13: 卸载 Jenkins 包"
  sudo apt remove --purge -y jenkins

  # 步骤 4/13: 删除数据目录
  log_info "步骤 4/13: 删除数据目录 ${JENKINS_HOME}"
  sudo rm -rf "$JENKINS_HOME"

  # 步骤 5/13: 删除日志目录
  log_info "步骤 5/13: 删除日志目录 ${JENKINS_LOG}"
  sudo rm -rf "$JENKINS_LOG"

  # 步骤 6/13: 删除缓存
  log_info "步骤 6/13: 删除缓存目录"
  sudo rm -rf /var/cache/jenkins

  # 步骤 7/13: 删除 APT 源
  log_info "步骤 7/13: 删除 APT 源"
  sudo rm -f /etc/apt/sources.list.d/jenkins.list

  # 步骤 8/13: 删除 keyring
  log_info "步骤 8/13: 删除 keyring"
  sudo rm -f /etc/apt/keyrings/jenkins-keyring.asc

  # 步骤 9/13: 删除 systemd override
  log_info "步骤 9/13: 删除 systemd override"
  sudo rm -rf "$JENKINS_OVERRIDE_DIR"

  # 步骤 10/13: 重新加载 systemd
  log_info "步骤 10/13: 重新加载 systemd"
  sudo systemctl daemon-reload

  # 步骤 11/13: 从 docker 组移除 jenkins 用户
  log_info "步骤 11/13: 从 docker 组移除 jenkins 用户"
  sudo gpasswd -d jenkins docker 2>/dev/null || true

  # 步骤 12/13: 删除 jenkins 系统用户
  log_info "步骤 12/13: 删除 jenkins 系统用户"
  sudo userdel jenkins 2>/dev/null || true

  # 步骤 13/13: 清理残留依赖
  log_info "步骤 13/13: 清理残留依赖"
  sudo apt autoremove -y

  log_success "=========================================="
  log_success "Jenkins 完全卸载完成"
  log_success "=========================================="
}

# ============================================
# cmd_status() — 检查 Jenkins 运行状态
# ============================================
cmd_status() {
  log_info "=========================================="
  log_info "Jenkins 状态检查"
  log_info "=========================================="

  local all_ok=true

  # 检查 1: Jenkins 包是否安装
  log_info "检查 1/5: Jenkins 包安装状态"
  if dpkg -l jenkins > /dev/null 2>&1; then
    local jenkins_version
    jenkins_version=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
    log_success "Jenkins 包已安装（版本: ${jenkins_version}）"
  else
    log_error "Jenkins 包未安装"
    all_ok=false
  fi

  # 检查 2: 服务状态
  log_info "检查 2/5: 服务状态"
  local service_status
  service_status=$(systemctl is-active jenkins 2>/dev/null || echo "unknown")
  if [ "$service_status" = "active" ]; then
    log_success "Jenkins 服务运行中（active）"
  else
    log_error "Jenkins 服务状态: ${service_status}"
    all_ok=false
  fi

  # 检查 3: 监听端口
  log_info "检查 3/5: 监听端口 ${JENKINS_PORT}"
  if curl -sf "http://localhost:${JENKINS_PORT}/login" > /dev/null 2>&1; then
    log_success "Jenkins 监听端口 ${JENKINS_PORT} 正常"
  else
    log_error "Jenkins 端口 ${JENKINS_PORT} 不可达"
    all_ok=false
  fi

  # 检查 4: Docker 权限
  log_info "检查 4/5: Docker 权限"
  if groups jenkins 2>/dev/null | grep -q docker; then
    log_success "jenkins 用户属于 docker 组"
  else
    log_error "jenkins 用户不属于 docker 组"
    all_ok=false
  fi

  # 检查 5: Jenkins 版本
  log_info "检查 5/5: Jenkins 版本"
  if command -v jenkins > /dev/null 2>&1; then
    jenkins --version 2>&1 || true
  elif dpkg -l jenkins > /dev/null 2>&1; then
    local ver
    ver=$(dpkg -s jenkins 2>/dev/null | grep '^Version:' | cut -d' ' -f2 || echo "未知")
    log_info "Jenkins 版本: ${ver}（从 dpkg 获取）"
  else
    log_info "无法获取 Jenkins 版本（未安装）"
  fi

  log_info "=========================================="
  if [ "$all_ok" = true ]; then
    log_success "所有检查通过"
  else
    log_warn "部分检查未通过，请查看上方详情"
  fi
  log_info "=========================================="
}

# ============================================
# 占位函数（Task 2 实现）
# ============================================
cmd_show_password() {
  log_info "此功能将在后续版本中实现"
}

cmd_restart() {
  log_info "此功能将在后续版本中实现"
}

cmd_upgrade() {
  log_info "此功能将在后续版本中实现"
}

cmd_reset_password() {
  log_info "此功能将在后续版本中实现"
}

# ============================================
# 子命令分发
# ============================================
case "${1:-}" in
  install)        cmd_install "$@" ;;
  uninstall)      cmd_uninstall "$@" ;;
  status)         cmd_status "$@" ;;
  show-password)  cmd_show_password "$@" ;;
  restart)        cmd_restart "$@" ;;
  upgrade)        cmd_upgrade "$@" ;;
  reset-password) cmd_reset_password "$@" ;;
  *)              usage && exit 1 ;;
esac
